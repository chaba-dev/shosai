//! Simplified XHTML → content model renderer for EPUB chapters.
//!
//! Parses EPUB chapter XHTML into a flat list of [`ContentNode`] values that
//! the GUI layer can map to native widgets. A bounded native CSS cascade maps
//! supported computed styles onto block and inline presentation values.

use anyhow::{Context, Result};
use std::collections::HashMap;
use std::sync::Arc;

use super::EpubLimits;

const MAX_CHAPTER_ANCHORS: usize = 4_096;
const MAX_ANCHOR_NAME_BYTES: usize = 1_024;

/// A styled span of inline text or bounded MathML replacement geometry.
#[derive(Debug, Clone, PartialEq)]
pub struct TextSpan {
    pub text: String,
    /// Native inline geometry. `text` remains its readable search and fallback contract.
    pub math: Option<super::MathContent>,
    /// First admitted embedded family from the computed CSS fallback list.
    pub font_family: Option<Arc<str>>,
    pub bold: bool,
    pub italic: bool,
    pub monospace: bool,
    /// Font size relative to the containing native block.
    pub font_size_multiplier: f32,
    /// Preserve source whitespace instead of applying normal HTML collapsing.
    pub preserve_whitespace: bool,
    /// If set, this span is a link to the given URL/href.
    pub link: Option<String>,
}

/// Style annotations that can be applied to any block-level content node.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct NodeStyle {
    /// Text alignment override.
    pub text_align: Option<super::style::TextAlignment>,
    /// Base direction for native bidi shaping.
    pub direction: super::style::TextDirection,
    /// Font size multiplier override.
    pub font_size_multiplier: Option<f32>,
    /// Left margin in em.
    pub margin_left_em: Option<f32>,
    /// Authored vertical block spacing in em.
    pub block_spacing_em: Option<f32>,
    /// Authored width retained for native replaced-element and table layout.
    pub width: Option<NodeWidth>,
    /// Authored maximum width retained for native replaced-element layout.
    pub max_width: Option<NodeWidth>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum NodeWidth {
    Percent(f32),
    Pixels(f32),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImageSize {
    pub width: u32,
    pub height: u32,
}

/// Semantic row-group role retained from an EPUB table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TableRowGroupKind {
    Head,
    Body,
    Foot,
}

/// A semantic table row group in source order.
#[derive(Debug, Clone, PartialEq)]
pub struct TableRowGroup {
    pub kind: TableRowGroupKind,
    pub rows: Vec<TableRow>,
}

/// One row in an EPUB table.
#[derive(Debug, Clone, PartialEq)]
pub struct TableRow {
    pub cells: Vec<TableCell>,
}

/// One header or data cell with retained span and accessibility metadata.
#[derive(Debug, Clone, PartialEq)]
pub struct TableCell {
    pub id: Option<String>,
    pub header: bool,
    pub scope: Option<String>,
    pub headers: Vec<String>,
    /// Source `rowspan`; zero means all remaining rows in the row group.
    pub row_span: u16,
    /// Source `colspan`; malformed or zero values use the HTML initial value.
    pub column_span: u16,
    /// Ordered content nodes retained from the cell. Entries in `block_starts`
    /// begin a source block and therefore have a newline before them in the
    /// shared text-offset contract.
    pub children: Vec<ContentNode>,
    pub block_starts: Vec<usize>,
    pub style: NodeStyle,
}

/// A content node in the simplified document model.
#[derive(Debug, Clone, PartialEq)]
pub enum ContentNode {
    /// A heading (level 1–6).
    Heading {
        level: u8,
        spans: Vec<TextSpan>,
        style: NodeStyle,
    },
    /// A paragraph with mixed inline formatting.
    Paragraph(Vec<TextSpan>, NodeStyle),
    /// A block quote (contains paragraphs).
    BlockQuote {
        children: Vec<ContentNode>,
        style: NodeStyle,
    },
    /// A semantic EPUB table. Layout is owned by the native app layer.
    Table {
        caption: Vec<TextSpan>,
        caption_style: Option<NodeStyle>,
        row_groups: Vec<TableRowGroup>,
        style: NodeStyle,
    },
    /// A bounded Presentation MathML expression with readable text fallback.
    Math {
        content: super::MathContent,
        style: NodeStyle,
        link: Option<String>,
    },
    /// An unordered list.
    UnorderedList(Vec<Vec<TextSpan>>),
    /// An ordered list.
    OrderedList {
        items: Vec<Vec<TextSpan>>,
        start: usize,
    },
    /// An image reference.
    Image {
        /// Path to the image within the EPUB archive.
        src: String,
        alt: String,
        style: NodeStyle,
        /// Figure caption retained with the image so pagination can keep them together.
        caption: Vec<TextSpan>,
        caption_style: Option<NodeStyle>,
        /// Intrinsic raster dimensions populated from the admitted EPUB resource.
        intrinsic_size: Option<ImageSize>,
    },
    /// A code block (`<pre>`, `<code>` block-level, or `<pre><code>`).
    CodeBlock {
        /// The raw code text.
        code: String,
        /// Optional language hint from class (e.g. "language-rust", "python").
        language: Option<String>,
    },
    /// Inline code (`<code>` inside a paragraph).
    InlineCode(String),
    /// A horizontal rule / thematic break.
    HorizontalRule,
}

impl ContentNode {
    /// Native block style retained for node kinds that support authored CSS.
    pub fn style(&self) -> Option<&NodeStyle> {
        match self {
            Self::Heading { style, .. }
            | Self::BlockQuote { style, .. }
            | Self::Table { style, .. }
            | Self::Math { style, .. }
            | Self::Image { style, .. } => Some(style),
            Self::Paragraph(_, style) => Some(style),
            _ => None,
        }
    }
}

/// Parse chapter XHTML into a list of content nodes.
///
/// `base_path` is the directory of the chapter within the EPUB archive,
/// used to resolve relative image `src` attributes.
/// `styles` contains admitted author stylesheets for the native cascade.
pub fn parse_chapter_xhtml(
    xhtml: &str,
    base_path: &str,
    styles: &super::style::EpubStyles,
) -> Vec<ContentNode> {
    parse_chapter_xhtml_with_limits(xhtml, base_path, styles, &EpubLimits::default())
        .unwrap_or_default()
}

pub(crate) fn parse_chapter_xhtml_with_limits(
    xhtml: &str,
    base_path: &str,
    styles: &super::style::EpubStyles,
    limits: &EpubLimits,
) -> Result<Vec<ContentNode>> {
    parse_chapter_xhtml_with_owner_and_limits(xhtml, base_path, None, styles, None, limits)
        .map(|parsed| parsed.nodes)
}

#[cfg(test)]
pub(crate) fn parse_chapter_xhtml_at_path_with_limits(
    xhtml: &str,
    chapter_path: &str,
    styles: &super::style::EpubStyles,
    fonts: &super::font::EpubFontBook,
    limits: &EpubLimits,
) -> Result<Vec<ContentNode>> {
    let base_path = chapter_path
        .rsplit_once('/')
        .map_or("", |(directory, _)| directory);
    parse_chapter_xhtml_with_owner_and_limits(
        xhtml,
        base_path,
        Some(chapter_path),
        styles,
        Some(fonts),
        limits,
    )
    .map(|parsed| parsed.nodes)
}

pub(crate) struct ParsedChapterContent {
    pub(crate) nodes: Vec<ContentNode>,
    pub(crate) anchor_offsets: HashMap<String, usize>,
}

pub(crate) fn parse_chapter_content_at_path_with_limits(
    xhtml: &str,
    chapter_path: &str,
    styles: &super::style::EpubStyles,
    fonts: &super::font::EpubFontBook,
    limits: &EpubLimits,
) -> Result<ParsedChapterContent> {
    let base_path = chapter_path
        .rsplit_once('/')
        .map_or("", |(directory, _)| directory);
    parse_chapter_xhtml_with_owner_and_limits(
        xhtml,
        base_path,
        Some(chapter_path),
        styles,
        Some(fonts),
        limits,
    )
}

fn parse_chapter_xhtml_with_owner_and_limits(
    xhtml: &str,
    base_path: &str,
    chapter_path: Option<&str>,
    styles: &super::style::EpubStyles,
    fonts: Option<&super::font::EpubFontBook>,
    limits: &EpubLimits,
) -> Result<ParsedChapterContent> {
    // XML parsers do not load the external XHTML DTD (and must not do so for
    // EPUB content). Resolve the fixed, local HTML entity table instead.
    let normalized_xhtml = resolve_xhtml_named_entities(xhtml);
    let parsing_options = roxmltree::ParsingOptions {
        allow_dtd: true,
        nodes_limit: u32::try_from(normalized_xhtml.len()).unwrap_or(u32::MAX),
        ..Default::default()
    };
    let doc = roxmltree::Document::parse_with_options(&normalized_xhtml, parsing_options)
        .with_context(|| {
            format!(
                "failed to parse EPUB chapter XHTML{}",
                chapter_path.map_or(String::new(), |path| format!(" at {path}"))
            )
        })?;

    let css = styles.document_css_with_owner(&doc, base_path, chapter_path, limits)?;
    let mut computed_styles =
        super::computed_style::compute_parsed_document_styles(&doc, &css, limits)?;
    computed_styles.resolve_font_families(chapter_path, fonts);

    // Find <body> (or fall back to root).
    let body = doc
        .descendants()
        .find(|n| n.tag_name().name() == "body")
        .unwrap_or(doc.root());
    if computed_styles
        .get(body)
        .is_some_and(|style| style.display == super::computed_style::DisplayRole::None)
    {
        return Ok(ParsedChapterContent {
            nodes: Vec::new(),
            anchor_offsets: HashMap::new(),
        });
    }

    let mut parsed = parse_block_children(body, base_path, &computed_styles);
    record_element_anchors(&body, 0, &mut parsed.anchor_offsets);
    Ok(parsed)
}

fn resolve_xhtml_named_entities(xhtml: &str) -> std::borrow::Cow<'_, str> {
    let mut output = String::new();
    let mut remainder = xhtml;
    let mut changed = false;
    while let Some(start) = remainder.find('&') {
        let (prefix, candidate) = remainder.split_at(start);
        output.push_str(prefix);
        let Some(end) = candidate.find(';') else {
            output.push_str(candidate);
            remainder = "";
            break;
        };
        let entity = &candidate[1..end];
        // Keep XML's built-ins encoded: inserting their literal values can
        // make otherwise valid XML malformed. Numeric and document-defined
        // entities are likewise left to roxmltree.
        let replacement = (!matches!(entity, "amp" | "apos" | "gt" | "lt" | "quot"))
            .then(|| quick_xml::escape::resolve_html5_entity(entity))
            .flatten();
        if let Some(replacement) = replacement {
            output.push_str(&quick_xml::escape::escape(replacement));
            changed = true;
        } else {
            output.push_str(&candidate[..=end]);
        }
        remainder = &candidate[end + 1..];
    }
    output.push_str(remainder);
    if changed {
        std::borrow::Cow::Owned(output)
    } else {
        std::borrow::Cow::Borrowed(xhtml)
    }
}

/// Parse block-level children of an element.
fn parse_block_children(
    parent: roxmltree::Node,
    base_path: &str,
    styles: &super::computed_style::ComputedDocumentStyles,
) -> ParsedChapterContent {
    let mut nodes = Vec::new();
    let mut anchor_offsets = HashMap::new();
    let mut text_offset = 0;

    for child in parent.children() {
        if !child.is_element() {
            if child.is_text() {
                let text = child.text().unwrap_or("").trim();
                if !text.is_empty() {
                    let node = ContentNode::Paragraph(
                        vec![TextSpan {
                            text: text.to_string(),
                            math: None,
                            font_family: None,
                            bold: false,
                            italic: false,
                            monospace: false,
                            font_size_multiplier: 1.0,
                            preserve_whitespace: false,
                            link: None,
                        }],
                        NodeStyle::default(),
                    );
                    text_offset +=
                        crate::search::extract_text_from_nodes(std::slice::from_ref(&node))
                            .chars()
                            .count();
                    nodes.push(node);
                }
            }
            continue;
        }

        let css_style = styles
            .get(child)
            .expect("computed style must exist for every element");

        // If `display: none`, skip entirely.
        if css_style.display == super::computed_style::DisplayRole::None {
            continue;
        }

        let child_text_offset = text_offset;
        let first_child_node = nodes.len();
        let mut nested_anchors = HashMap::new();
        record_element_anchors(&child, child_text_offset, &mut anchor_offsets);

        // If the CSS says monospace + preserve-whitespace, treat as code block
        // regardless of the HTML tag (handles Calibre-generated classes).
        if !matches!(child.tag_name().name(), "pre" | "code")
            && css_style.monospace
            && css_style.preserve_whitespace
            && !super::math::is_math(child)
        {
            let code = collect_visible_text_content(&child, styles);
            if !code.trim().is_empty() {
                let node = ContentNode::CodeBlock {
                    code: code.trim().to_string(),
                    language: None,
                };
                record_element_anchors(&child, child_text_offset, &mut anchor_offsets);
                text_offset += crate::search::extract_text_from_nodes(std::slice::from_ref(&node))
                    .chars()
                    .count();
                nodes.push(node);
                continue;
            }
        }

        let node_style = css_to_node_style(css_style, child.tag_name().name());

        match child.tag_name().name() {
            "h1" => nested_anchors = push_heading(&mut nodes, &child, 1, &node_style, styles),
            "h2" => nested_anchors = push_heading(&mut nodes, &child, 2, &node_style, styles),
            "h3" => nested_anchors = push_heading(&mut nodes, &child, 3, &node_style, styles),
            "h4" => nested_anchors = push_heading(&mut nodes, &child, 4, &node_style, styles),
            "h5" => nested_anchors = push_heading(&mut nodes, &child, 5, &node_style, styles),
            "h6" => nested_anchors = push_heading(&mut nodes, &child, 6, &node_style, styles),

            "p" => {
                let inline = collect_inline_content(&child, styles, css_style.font_size_px);
                nested_anchors = inline.anchors;
                let spans = inline.spans;
                let mut paragraph = Vec::new();
                let mut source_offset = 0;
                let mut paragraph_source_start = 0;
                let mut emitted_node = false;
                let mut separator_boundaries = Vec::new();
                for span in spans {
                    let span_len = span.text.chars().count();
                    if span
                        .math
                        .as_ref()
                        .is_some_and(|math| math.display == super::MathDisplay::Block)
                    {
                        if !paragraph.is_empty() {
                            if emitted_node {
                                separator_boundaries.push(paragraph_source_start);
                            }
                            nodes.push(ContentNode::Paragraph(
                                std::mem::take(&mut paragraph),
                                node_style.clone(),
                            ));
                            emitted_node = true;
                        }
                        if emitted_node {
                            separator_boundaries.push(source_offset);
                        }
                        nodes.push(ContentNode::Math {
                            content: span.math.expect("checked block math"),
                            style: NodeStyle {
                                font_size_multiplier: Some(span.font_size_multiplier),
                                ..node_style.clone()
                            },
                            link: span.link,
                        });
                        emitted_node = true;
                        paragraph_source_start = source_offset + span_len;
                    } else {
                        paragraph.push(span);
                    }
                    source_offset += span_len;
                }
                if !paragraph.is_empty() {
                    if emitted_node {
                        separator_boundaries.push(paragraph_source_start);
                    }
                    nodes.push(ContentNode::Paragraph(paragraph, node_style));
                }
                for offset in nested_anchors.values_mut() {
                    *offset += separator_boundaries
                        .iter()
                        .filter(|boundary| **boundary <= *offset)
                        .count();
                }
            }

            "blockquote" => {
                let inner = parse_block_children(child, base_path, styles);
                if !inner.nodes.is_empty() {
                    nested_anchors = inner.anchor_offsets;
                    nodes.push(ContentNode::BlockQuote {
                        children: inner.nodes,
                        style: node_style,
                    });
                }
            }

            "table" => {
                if let Some(table) = parse_table(&child, base_path, styles, node_style) {
                    nested_anchors = table_anchor_offsets(&child, &table, base_path, styles);
                    nodes.push(table);
                }
            }

            "math" if super::math::is_math(child) => {
                nodes.push(ContentNode::Math {
                    content: super::math::parse_math(child),
                    style: node_style,
                    link: None,
                });
            }

            "ul" => {
                let (items, anchors) = parse_list_items(&child, styles);
                if !items.is_empty() {
                    nested_anchors = anchors;
                    nodes.push(ContentNode::UnorderedList(items));
                }
            }

            "ol" => {
                let (items, anchors) = parse_list_items(&child, styles);
                if !items.is_empty() {
                    nested_anchors = anchors;
                    let start = child
                        .attribute("start")
                        .and_then(|value| value.parse().ok())
                        .unwrap_or(1);
                    nodes.push(ContentNode::OrderedList { items, start });
                }
            }

            "pre" => {
                let language = extract_language_hint(&child);
                let code = collect_visible_text_content(&child, styles);
                if !code.trim().is_empty() {
                    nodes.push(ContentNode::CodeBlock {
                        code: code.trim().to_string(),
                        language,
                    });
                }
            }

            "code" => {
                let language = extract_language_hint(&child);
                let code = collect_visible_text_content(&child, styles);
                if !code.trim().is_empty() {
                    nodes.push(ContentNode::CodeBlock {
                        code: code.trim().to_string(),
                        language,
                    });
                }
            }

            "img" => {
                if let Some(src) = child.attribute("src") {
                    let alt = child.attribute("alt").unwrap_or("").to_string();
                    if let Some(src) = resolve_relative(base_path, src) {
                        nodes.push(ContentNode::Image {
                            src,
                            alt,
                            style: node_style,
                            caption: Vec::new(),
                            caption_style: None,
                            intrinsic_size: None,
                        });
                    } else if !alt.is_empty() {
                        nodes.push(ContentNode::Paragraph(
                            vec![text_span_for_node(&child, alt, None, styles, 16.0)],
                            node_style,
                        ));
                    }
                }
            }

            "hr" => {
                nodes.push(ContentNode::HorizontalRule);
            }

            "figure" => {
                if let Some((figure, anchors)) =
                    parse_figure(&child, base_path, styles, &node_style)
                {
                    nested_anchors = anchors;
                    nodes.push(figure);
                } else {
                    let inner = parse_block_children(child, base_path, styles);
                    nested_anchors = inner.anchor_offsets;
                    nodes.extend(collapse_figure(inner.nodes, node_style));
                }
            }

            "div" | "section" | "article" | "main" | "aside" | "header" | "footer"
            | "figcaption" => {
                let inner = parse_block_children(child, base_path, styles);
                nested_anchors = inner.anchor_offsets;
                nodes.extend(inner.nodes);
            }

            _ => {
                let inline = collect_inline_content(&child, styles, css_style.font_size_px);
                nested_anchors = inline.anchors;
                if !inline.spans.is_empty() {
                    nodes.push(ContentNode::Paragraph(inline.spans, node_style));
                }
            }
        }

        for (name, offset) in nested_anchors {
            record_anchor_name(&name, child_text_offset + offset, &mut anchor_offsets);
        }
        if nodes.len() > first_child_node {
            text_offset += crate::search::extract_text_from_nodes(&nodes[first_child_node..])
                .chars()
                .count();
        }
    }

    ParsedChapterContent {
        nodes,
        anchor_offsets,
    }
}

fn parse_figure(
    figure: &roxmltree::Node<'_, '_>,
    base_path: &str,
    styles: &super::computed_style::ComputedDocumentStyles,
    figure_style: &NodeStyle,
) -> Option<(ContentNode, HashMap<String, usize>)> {
    let visible = |node: roxmltree::Node<'_, '_>| {
        styles
            .get(node)
            .is_some_and(|style| style.display != super::computed_style::DisplayRole::None)
    };
    let images = figure
        .descendants()
        .filter(|node| node.is_element() && node.tag_name().name() == "img" && visible(*node))
        .collect::<Vec<_>>();
    if images.len() != 1 {
        return None;
    }
    let image = images[0];
    let src = resolve_relative(base_path, image.attribute("src")?)?;
    let alt = image.attribute("alt").unwrap_or("").to_owned();
    let mut style = css_to_node_style(styles.get(image)?, "img");
    if figure_style.block_spacing_em.is_some() {
        style.block_spacing_em = figure_style.block_spacing_em;
    }
    let captions = figure
        .children()
        .filter(|node| {
            node.is_element() && node.tag_name().name() == "figcaption" && visible(*node)
        })
        .collect::<Vec<_>>();
    let caption_node = captions
        .first()
        .copied()
        .filter(|node| figure.children().find(|child| child.is_element()) == Some(*node))
        .or_else(|| {
            captions.last().copied().filter(|node| {
                figure
                    .children()
                    .filter(|child| child.is_element())
                    .next_back()
                    == Some(*node)
            })
        })?;
    let mut caption_anchors = HashMap::new();
    let (caption, caption_style) = {
        let css = styles
            .get(caption_node)
            .expect("caption has computed style");
        let mut spans = Vec::new();
        for child in caption_node
            .children()
            .filter(|child| child.is_element() && visible(*child))
        {
            let inline = collect_inline_content(&child, styles, css.font_size_px);
            let mut block = inline.spans;
            if !spans.is_empty() && !block.is_empty() {
                let mut separator = block[0].clone();
                separator.text = "\n".to_owned();
                separator.math = None;
                spans.push(separator);
            }
            let block_offset = spans.iter().map(|span| span.text.chars().count()).sum();
            record_element_anchors(&child, block_offset, &mut caption_anchors);
            for (name, offset) in inline.anchors {
                record_anchor_name(&name, block_offset + offset, &mut caption_anchors);
            }
            spans.append(&mut block);
        }
        if spans.is_empty() {
            spans = collect_inline_content(&caption_node, styles, css.font_size_px).spans;
        }
        (spans, Some(css_to_node_style(css, "figcaption")))
    };
    let mut anchors = HashMap::new();
    record_element_anchors(&image, 0, &mut anchors);
    let caption_offset = alt.chars().count() + usize::from(!caption.is_empty());
    record_element_anchors(&caption_node, caption_offset, &mut anchors);
    for (name, offset) in caption_anchors {
        record_anchor_name(&name, caption_offset + offset, &mut anchors);
    }
    Some((
        ContentNode::Image {
            src,
            alt,
            style,
            caption,
            caption_style,
            intrinsic_size: None,
        },
        anchors,
    ))
}

fn collapse_figure(mut nodes: Vec<ContentNode>, figure_style: NodeStyle) -> Vec<ContentNode> {
    if nodes.len() != 2 || !matches!(nodes.first(), Some(ContentNode::Image { .. })) {
        return nodes;
    }
    let (caption, caption_style) = match nodes.pop().expect("figure has two nodes") {
        ContentNode::Heading { spans, style, .. } | ContentNode::Paragraph(spans, style) => {
            (spans, style)
        }
        other => {
            nodes.push(other);
            return nodes;
        }
    };
    let Some(ContentNode::Image {
        style,
        caption: image_caption,
        caption_style: image_caption_style,
        ..
    }) = nodes.first_mut()
    else {
        unreachable!("checked image node");
    };
    if figure_style.block_spacing_em.is_some() {
        style.block_spacing_em = figure_style.block_spacing_em;
    }
    *image_caption = caption;
    *image_caption_style = Some(caption_style);
    nodes
}

fn record_element_anchors(
    element: &roxmltree::Node<'_, '_>,
    offset: usize,
    anchors: &mut HashMap<String, usize>,
) {
    let names = element.attribute("id").into_iter().chain(
        (element.tag_name().name() == "a")
            .then(|| element.attribute("name"))
            .flatten(),
    );
    for name in names {
        record_anchor_name(name, offset, anchors);
    }
}

fn record_anchor_name(name: &str, offset: usize, anchors: &mut HashMap<String, usize>) {
    if anchors.len() >= MAX_CHAPTER_ANCHORS
        || name.is_empty()
        || name.len() > MAX_ANCHOR_NAME_BYTES
        || name.chars().any(|character| character.is_control())
    {
        return;
    }
    anchors.entry(name.to_owned()).or_insert(offset);
}

fn table_anchor_offsets(
    source: &roxmltree::Node<'_, '_>,
    table: &ContentNode,
    base_path: &str,
    styles: &super::computed_style::ComputedDocumentStyles,
) -> HashMap<String, usize> {
    let ContentNode::Table {
        caption,
        row_groups,
        ..
    } = table
    else {
        return HashMap::new();
    };
    let mut anchors = HashMap::new();
    if let Some(source_caption) = source.children().find(|child| {
        child.is_element()
            && child.tag_name().name() == "caption"
            && styles
                .get(*child)
                .is_none_or(|style| style.display != super::computed_style::DisplayRole::None)
    }) {
        record_element_anchors(&source_caption, 0, &mut anchors);
        let font_size = styles
            .get(source_caption)
            .expect("computed style must exist for table caption")
            .font_size_px;
        for (name, offset) in collect_inline_content(&source_caption, styles, font_size).anchors {
            record_anchor_name(&name, offset, &mut anchors);
        }
    }
    let mut offset = caption
        .iter()
        .map(|span| span.text.chars().count())
        .sum::<usize>();
    offset += usize::from(!caption.is_empty());

    let source_rows = visible_table_rows(source, styles);
    let rows = row_groups.iter().flat_map(|group| &group.rows);
    for (source_row, row) in source_rows.into_iter().zip(rows) {
        record_element_anchors(&source_row, offset, &mut anchors);
        let source_cells = source_row.children().filter(|cell| {
            cell.is_element()
                && matches!(cell.tag_name().name(), "th" | "td")
                && styles
                    .get(*cell)
                    .is_some_and(|style| style.display != super::computed_style::DisplayRole::None)
        });
        for (cell_index, (source_cell, cell)) in source_cells.zip(&row.cells).enumerate() {
            record_element_anchors(&source_cell, offset, &mut anchors);
            let has_block_children = source_cell.children().any(|child| {
                child.is_element()
                    && styles.get(child).is_some_and(|style| {
                        style.display != super::computed_style::DisplayRole::None
                            && style.display != super::computed_style::DisplayRole::Inline
                    })
            });
            let nested = if has_block_children {
                parse_block_children(source_cell, base_path, styles).anchor_offsets
            } else {
                let font_size = styles
                    .get(source_cell)
                    .expect("computed style must exist for table cell")
                    .font_size_px;
                collect_inline_content(&source_cell, styles, font_size).anchors
            };
            for (name, nested_offset) in nested {
                record_anchor_name(&name, offset + nested_offset, &mut anchors);
            }
            for (child_index, child) in cell.children.iter().enumerate() {
                if cell.block_starts.contains(&child_index) {
                    offset += 1;
                }
                offset += crate::search::extract_text_from_nodes(std::slice::from_ref(child))
                    .chars()
                    .count()
                    .saturating_sub(1);
            }
            offset += usize::from(cell_index + 1 < row.cells.len());
        }
        offset += 1;
    }
    anchors
}

fn visible_table_rows<'a>(
    table: &roxmltree::Node<'a, 'a>,
    styles: &super::computed_style::ComputedDocumentStyles,
) -> Vec<roxmltree::Node<'a, 'a>> {
    let visible_row = |row: roxmltree::Node<'a, 'a>| {
        row.is_element()
            && row.tag_name().name() == "tr"
            && styles
                .get(row)
                .is_some_and(|style| style.display != super::computed_style::DisplayRole::None)
            && row.children().any(|cell| {
                cell.is_element()
                    && matches!(cell.tag_name().name(), "th" | "td")
                    && styles.get(cell).is_some_and(|style| {
                        style.display != super::computed_style::DisplayRole::None
                    })
            })
    };
    table
        .children()
        .filter(roxmltree::Node::is_element)
        .flat_map(|child| match child.tag_name().name() {
            "tr" => visible_row(child).then_some(child).into_iter().collect(),
            "thead" | "tbody" | "tfoot" => child
                .children()
                .filter(|row| visible_row(*row))
                .collect::<Vec<_>>(),
            _ => Vec::new(),
        })
        .collect()
}

fn parse_table(
    table: &roxmltree::Node,
    base_path: &str,
    styles: &super::computed_style::ComputedDocumentStyles,
    style: NodeStyle,
) -> Option<ContentNode> {
    let caption = table
        .children()
        .find(|child| child.is_element() && child.tag_name().name() == "caption")
        .filter(|caption| {
            styles
                .get(*caption)
                .is_none_or(|style| style.display != super::computed_style::DisplayRole::None)
        })
        .map(|caption| {
            let css = styles
                .get(caption)
                .expect("computed style must exist for table caption");
            (
                collect_inline_spans(&caption, styles, css.font_size_px),
                css_to_node_style(css, "caption"),
            )
        })
        .filter(|(spans, _)| !spans.is_empty());
    let (caption, caption_style) =
        caption.map_or_else(|| (Vec::new(), None), |(spans, style)| (spans, Some(style)));
    let mut row_groups = Vec::new();
    let mut implicit_body = Vec::new();
    for child in table.children().filter(roxmltree::Node::is_element) {
        if styles
            .get(child)
            .is_some_and(|style| style.display == super::computed_style::DisplayRole::None)
        {
            continue;
        }
        match child.tag_name().name() {
            "thead" | "tbody" | "tfoot" => {
                flush_implicit_table_rows(&mut row_groups, &mut implicit_body);
                let kind = match child.tag_name().name() {
                    "thead" => TableRowGroupKind::Head,
                    "tfoot" => TableRowGroupKind::Foot,
                    _ => TableRowGroupKind::Body,
                };
                let rows = child
                    .children()
                    .filter(|row| row.is_element() && row.tag_name().name() == "tr")
                    .filter_map(|row| parse_table_row(&row, base_path, styles))
                    .collect::<Vec<_>>();
                if !rows.is_empty() {
                    row_groups.push(TableRowGroup { kind, rows });
                }
            }
            "tr" => {
                if let Some(row) = parse_table_row(&child, base_path, styles) {
                    implicit_body.push(row);
                }
            }
            _ => {}
        }
    }
    flush_implicit_table_rows(&mut row_groups, &mut implicit_body);
    (!caption.is_empty() || !row_groups.is_empty()).then_some(ContentNode::Table {
        caption,
        caption_style,
        row_groups,
        style,
    })
}

fn flush_implicit_table_rows(groups: &mut Vec<TableRowGroup>, rows: &mut Vec<TableRow>) {
    if !rows.is_empty() {
        groups.push(TableRowGroup {
            kind: TableRowGroupKind::Body,
            rows: std::mem::take(rows),
        });
    }
}

fn parse_table_row(
    row: &roxmltree::Node,
    base_path: &str,
    styles: &super::computed_style::ComputedDocumentStyles,
) -> Option<TableRow> {
    if styles
        .get(*row)
        .is_some_and(|style| style.display == super::computed_style::DisplayRole::None)
    {
        return None;
    }
    let cells = row
        .children()
        .filter(|cell| cell.is_element() && matches!(cell.tag_name().name(), "th" | "td"))
        .filter_map(|cell| parse_table_cell(&cell, base_path, styles))
        .collect::<Vec<_>>();
    (!cells.is_empty()).then_some(TableRow { cells })
}

fn parse_table_cell(
    cell: &roxmltree::Node,
    base_path: &str,
    styles: &super::computed_style::ComputedDocumentStyles,
) -> Option<TableCell> {
    let css = styles.get(*cell)?;
    if css.display == super::computed_style::DisplayRole::None {
        return None;
    }
    let cell_style = css_to_node_style(css, cell.tag_name().name());
    let blocks =
        collect_table_cell_blocks(cell, base_path, styles, &cell_style, css.font_size_px, None);
    let mut children = Vec::new();
    let mut block_starts = Vec::new();
    for block in blocks {
        if !children.is_empty() {
            block_starts.push(children.len());
        }
        for child in block {
            if matches!(child, ContentNode::Math { .. }) && !children.is_empty() {
                block_starts.push(children.len());
            }
            let was_math = matches!(child, ContentNode::Math { .. });
            children.push(child);
            if was_math {
                block_starts.push(children.len());
            }
        }
    }
    block_starts.sort_unstable();
    block_starts.dedup();
    block_starts.retain(|start| *start < children.len());
    Some(TableCell {
        id: cell.attribute("id").map(str::to_owned),
        header: cell.tag_name().name() == "th",
        scope: cell.attribute("scope").map(str::to_owned),
        headers: cell.attribute("headers").map_or_else(Vec::new, |headers| {
            headers.split_whitespace().map(str::to_owned).collect()
        }),
        row_span: table_row_span(cell.attribute("rowspan")),
        column_span: table_column_span(cell.attribute("colspan")),
        children,
        block_starts,
        style: cell_style,
    })
}

fn collect_table_cell_blocks(
    parent: &roxmltree::Node,
    base_path: &str,
    styles: &super::computed_style::ComputedDocumentStyles,
    block_style: &NodeStyle,
    base_font_size: f32,
    link: Option<&str>,
) -> Vec<Vec<ContentNode>> {
    let mut blocks = Vec::new();
    let mut children = Vec::new();
    let mut spans = Vec::new();
    for child in parent.children() {
        let child_is_block = child.is_element()
            && styles.get(child).is_some_and(|style| {
                matches!(
                    style.display,
                    super::computed_style::DisplayRole::Block
                        | super::computed_style::DisplayRole::Table
                        | super::computed_style::DisplayRole::TableRowGroup
                        | super::computed_style::DisplayRole::TableRow
                        | super::computed_style::DisplayRole::TableCell
                        | super::computed_style::DisplayRole::TableCaption
                )
            });
        if child_is_block {
            flush_table_cell_spans(&mut spans, &mut children, block_style);
            if !children.is_empty() {
                blocks.push(std::mem::take(&mut children));
            }
            let css = styles
                .get(child)
                .expect("computed style must exist for table cell block");
            if css.display != super::computed_style::DisplayRole::None {
                let style = css_to_node_style(css, child.tag_name().name());
                blocks.extend(collect_table_cell_blocks(
                    &child,
                    base_path,
                    styles,
                    &style,
                    css.font_size_px,
                    link,
                ));
            }
        } else {
            collect_table_cell_inline(
                &child,
                base_path,
                styles,
                block_style,
                base_font_size,
                link,
                &mut spans,
                &mut children,
            );
        }
    }
    flush_table_cell_spans(&mut spans, &mut children, block_style);
    if !children.is_empty() {
        blocks.push(children);
    }
    blocks
}

#[allow(clippy::too_many_arguments)]
fn collect_table_cell_inline(
    node: &roxmltree::Node,
    base_path: &str,
    styles: &super::computed_style::ComputedDocumentStyles,
    block_style: &NodeStyle,
    base_font_size: f32,
    link: Option<&str>,
    spans: &mut Vec<TextSpan>,
    children: &mut Vec<ContentNode>,
) {
    if node.is_text() {
        let text = node.text().unwrap_or("");
        if !text.is_empty() {
            let parent = node
                .parent()
                .expect("table cell text must have an element parent");
            spans.push(text_span_for_node(
                &parent,
                text.to_owned(),
                link,
                styles,
                base_font_size,
            ));
        }
        return;
    }
    if !node.is_element() {
        return;
    }
    let css = styles
        .get(*node)
        .expect("computed style must exist for table cell content");
    if css.display == super::computed_style::DisplayRole::None {
        return;
    }
    if super::math::is_math(*node) {
        let content = super::math::parse_math(*node);
        if content.display == super::MathDisplay::Block {
            flush_table_cell_spans(spans, children, block_style);
            children.push(ContentNode::Math {
                content,
                style: NodeStyle {
                    font_size_multiplier: Some(css.font_size_px / base_font_size),
                    ..block_style.clone()
                },
                link: link.map(str::to_owned),
            });
        } else {
            spans.push(TextSpan {
                text: content.fallback.clone(),
                math: Some(content),
                font_family: css.font_families.first().cloned(),
                bold: css.bold,
                italic: css.italic,
                monospace: false,
                font_size_multiplier: css.font_size_px / base_font_size,
                preserve_whitespace: false,
                link: link.map(str::to_owned),
            });
        }
        return;
    }
    if node.tag_name().name() == "img" {
        let alt = node.attribute("alt").unwrap_or("");
        let Some(raw_src) = node.attribute("src") else {
            if !alt.is_empty() {
                spans.push(text_span_for_node(
                    node,
                    alt.to_owned(),
                    link,
                    styles,
                    base_font_size,
                ));
            }
            return;
        };
        let Some(src) = resolve_relative(base_path, raw_src) else {
            if !alt.is_empty() {
                spans.push(text_span_for_node(
                    node,
                    alt.to_owned(),
                    link,
                    styles,
                    base_font_size,
                ));
            }
            return;
        };
        flush_table_cell_spans(spans, children, block_style);
        children.push(ContentNode::Image {
            src,
            alt: alt.to_owned(),
            style: css_to_node_style(
                styles
                    .get(*node)
                    .expect("computed style must exist for image"),
                "img",
            ),
            caption: Vec::new(),
            caption_style: None,
            intrinsic_size: None,
        });
        return;
    }
    let nested_link = if node.tag_name().name() == "a" {
        node.attribute("href")
    } else {
        link
    };
    for child in node.children() {
        collect_table_cell_inline(
            &child,
            base_path,
            styles,
            block_style,
            base_font_size,
            nested_link,
            spans,
            children,
        );
    }
}

fn flush_table_cell_spans(
    spans: &mut Vec<TextSpan>,
    children: &mut Vec<ContentNode>,
    style: &NodeStyle,
) {
    collapse_inline_whitespace(spans);
    merge_spans(spans);
    if !spans.is_empty() {
        children.push(ContentNode::Paragraph(std::mem::take(spans), style.clone()));
    }
}

fn text_span_for_node(
    node: &roxmltree::Node,
    text: String,
    link: Option<&str>,
    styles: &super::computed_style::ComputedDocumentStyles,
    base_font_size: f32,
) -> TextSpan {
    let style = styles
        .get(*node)
        .expect("computed style must exist for text owner");
    TextSpan {
        text,
        math: None,
        font_family: style.font_families.first().cloned(),
        bold: style.bold,
        italic: style.italic,
        monospace: style.monospace,
        font_size_multiplier: style.font_size_px / base_font_size,
        preserve_whitespace: style.preserve_whitespace,
        link: link.map(str::to_owned),
    }
}

fn table_row_span(value: Option<&str>) -> u16 {
    const MAX_ROW_SPAN: u64 = 65_534;
    value
        .and_then(parse_table_span_number)
        .map(|value| value.min(MAX_ROW_SPAN) as u16)
        .unwrap_or(1)
}

fn table_column_span(value: Option<&str>) -> u16 {
    const MAX_COLUMN_SPAN: u64 = 1_000;
    value
        .and_then(parse_table_span_number)
        .filter(|value| *value > 0)
        .map(|value| value.min(MAX_COLUMN_SPAN) as u16)
        .unwrap_or(1)
}

fn parse_table_span_number(value: &str) -> Option<u64> {
    value.parse::<u64>().ok().or_else(|| {
        (!value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit())).then_some(u64::MAX)
    })
}

/// Convert a fully computed CSS style to native block annotations.
fn css_to_node_style(css: &super::computed_style::ComputedStyle, tag: &str) -> NodeStyle {
    use super::computed_style::{Alignment, Direction};

    let semantic_scale = match tag {
        "h1" => 2.0,
        "h2" => 1.6,
        "h3" => 1.3,
        "h4" => 1.1,
        _ => 1.0,
    };
    let font_size_multiplier = css.font_size_px / (16.0 * semantic_scale);
    let margin_left_em = css.margin_left_px / 16.0;
    let block_spacing_em = css
        .margin_top_px
        .into_iter()
        .chain(css.margin_bottom_px)
        .reduce(f32::max)
        .map(|spacing| spacing / 16.0);
    let text_indent_em = css.text_indent_px / 16.0;
    NodeStyle {
        text_align: Some(match css.alignment {
            Alignment::Start => match css.direction {
                Direction::Ltr => super::style::TextAlignment::Left,
                Direction::Rtl => super::style::TextAlignment::Right,
            },
            Alignment::End => match css.direction {
                Direction::Ltr => super::style::TextAlignment::Right,
                Direction::Rtl => super::style::TextAlignment::Left,
            },
            Alignment::Left => super::style::TextAlignment::Left,
            Alignment::Right => super::style::TextAlignment::Right,
            Alignment::Center => super::style::TextAlignment::Center,
            Alignment::Justify => super::style::TextAlignment::Justify,
        }),
        direction: match css.direction {
            Direction::Ltr => super::style::TextDirection::Ltr,
            Direction::Rtl => super::style::TextDirection::Rtl,
        },
        font_size_multiplier: ((font_size_multiplier - 1.0).abs() > f32::EPSILON)
            .then_some(font_size_multiplier),
        // A negative text indent commonly cancels the containing margin on
        // the first line to create a hanging indent. Native text widgets do
        // not expose first-line indentation, so use the first-line origin
        // rather than incorrectly shifting the entire paragraph inward.
        margin_left_em: if text_indent_em < 0.0 {
            Some((margin_left_em + text_indent_em).max(0.0))
        } else if margin_left_em.abs() > f32::EPSILON {
            Some(margin_left_em)
        } else {
            None
        },
        block_spacing_em,
        width: css.width.map(|width| match width {
            super::computed_style::ComputedWidth::Percent(value) => NodeWidth::Percent(value),
            super::computed_style::ComputedWidth::Px(value) => NodeWidth::Pixels(value),
        }),
        max_width: css.max_width.map(|width| match width {
            super::computed_style::ComputedWidth::Percent(value) => NodeWidth::Percent(value),
            super::computed_style::ComputedWidth::Px(value) => NodeWidth::Pixels(value),
        }),
    }
}

/// Collect heading text content.
fn push_heading(
    nodes: &mut Vec<ContentNode>,
    element: &roxmltree::Node,
    level: u8,
    node_style: &NodeStyle,
    styles: &super::computed_style::ComputedDocumentStyles,
) -> HashMap<String, usize> {
    let font_size = styles
        .get(*element)
        .expect("computed style must exist for heading")
        .font_size_px;
    let inline = collect_inline_content(element, styles, font_size);
    if !inline.spans.is_empty() {
        nodes.push(ContentNode::Heading {
            level,
            spans: inline.spans,
            style: node_style.clone(),
        });
    }
    inline.anchors
}

/// Parse <li> items from a <ul> or <ol>.
fn parse_list_items(
    list: &roxmltree::Node,
    styles: &super::computed_style::ComputedDocumentStyles,
) -> (Vec<Vec<TextSpan>>, HashMap<String, usize>) {
    let mut items = Vec::new();
    let mut anchors = HashMap::new();
    let mut text_offset = 0;
    for child in list.children() {
        if child.is_element() && child.tag_name().name() == "li" {
            if styles
                .get(child)
                .is_some_and(|style| style.display == super::computed_style::DisplayRole::None)
            {
                continue;
            }
            let inline = collect_inline_content(&child, styles, 16.0);
            if !inline.spans.is_empty() {
                record_element_anchors(&child, text_offset, &mut anchors);
                for (name, offset) in inline.anchors {
                    record_anchor_name(&name, text_offset + offset, &mut anchors);
                }
                text_offset += inline
                    .spans
                    .iter()
                    .map(|span| span.text.chars().count())
                    .sum::<usize>()
                    + 1;
                items.push(inline.spans);
            }
        }
    }
    (items, anchors)
}

/// Collect inline text spans with bold/italic formatting from an element.
fn collect_inline_spans(
    element: &roxmltree::Node,
    styles: &super::computed_style::ComputedDocumentStyles,
    base_font_size: f32,
) -> Vec<TextSpan> {
    collect_inline_content(element, styles, base_font_size).spans
}

struct InlineContent {
    spans: Vec<TextSpan>,
    anchors: HashMap<String, usize>,
}

fn collect_inline_content(
    element: &roxmltree::Node,
    styles: &super::computed_style::ComputedDocumentStyles,
    base_font_size: f32,
) -> InlineContent {
    let mut spans = Vec::new();
    let mut anchors = HashMap::new();
    let mut raw_offset = 0;
    collect_inline_spans_recursive(
        element,
        base_font_size,
        None,
        styles,
        &mut spans,
        &mut anchors,
        &mut raw_offset,
    );

    // XHTML follows HTML whitespace rules for normal inline content: source
    // line breaks and indentation collapse to a single space. Preserve raw
    // whitespace only in code blocks, which do not use this collector.
    collapse_inline_whitespace_with_anchors(&mut spans, &mut anchors);

    // Merge adjacent spans with the same formatting.
    merge_spans(&mut spans);
    InlineContent { spans, anchors }
}

fn collapse_inline_whitespace(spans: &mut Vec<TextSpan>) {
    collapse_inline_whitespace_with_anchors(spans, &mut HashMap::new());
}

fn collapse_inline_whitespace_with_anchors(
    spans: &mut Vec<TextSpan>,
    anchors: &mut HashMap<String, usize>,
) {
    let mut at_start_or_whitespace = true;
    let raw_len = spans
        .iter()
        .map(|span| span.text.chars().count())
        .sum::<usize>();
    let mut normalized_boundaries = vec![0; raw_len + 1];
    let mut raw_offset = 0_usize;
    let mut normalized_offset = 0_usize;
    for span in spans.iter_mut() {
        if span.math.is_some() {
            at_start_or_whitespace = span
                .text
                .chars()
                .last()
                .is_none_or(|character| character.is_ascii_whitespace());
            for _ in span.text.chars() {
                raw_offset += 1;
                normalized_offset += 1;
                normalized_boundaries[raw_offset] = normalized_offset;
            }
            continue;
        }
        if span.preserve_whitespace {
            at_start_or_whitespace = span
                .text
                .chars()
                .last()
                .is_none_or(|character| character.is_ascii_whitespace());
            for _ in span.text.chars() {
                raw_offset += 1;
                normalized_offset += 1;
                normalized_boundaries[raw_offset] = normalized_offset;
            }
            continue;
        }
        let mut normalized = String::with_capacity(span.text.len());
        for character in span.text.chars() {
            if character.is_ascii_whitespace() {
                if !at_start_or_whitespace {
                    normalized.push(' ');
                    normalized_offset += 1;
                    at_start_or_whitespace = true;
                }
            } else {
                normalized.push(character);
                normalized_offset += 1;
                at_start_or_whitespace = false;
            }
            raw_offset += 1;
            normalized_boundaries[raw_offset] = normalized_offset;
        }
        span.text = normalized;
    }

    if let Some(last) = spans
        .iter_mut()
        .rfind(|span| !span.text.is_empty() && !span.preserve_whitespace)
        && last.text.ends_with(' ')
    {
        last.text.pop();
        normalized_offset = normalized_offset.saturating_sub(1);
    }
    spans.retain(|span| !span.text.is_empty());
    for offset in anchors.values_mut() {
        *offset = normalized_boundaries
            .get(*offset)
            .copied()
            .unwrap_or(normalized_offset)
            .min(normalized_offset);
    }
}

fn collect_inline_spans_recursive(
    node: &roxmltree::Node,
    base_font_size: f32,
    link: Option<&str>,
    styles: &super::computed_style::ComputedDocumentStyles,
    spans: &mut Vec<TextSpan>,
    anchors: &mut HashMap<String, usize>,
    raw_offset: &mut usize,
) {
    let style = styles
        .get(*node)
        .expect("computed style must exist for every element");
    for child in node.children() {
        if child.is_text() {
            let text = child.text().unwrap_or("");
            if !text.is_empty() {
                *raw_offset += text.chars().count();
                spans.push(TextSpan {
                    text: text.to_string(),
                    math: None,
                    font_family: style.font_families.first().cloned(),
                    bold: style.bold,
                    italic: style.italic,
                    monospace: style.monospace,
                    font_size_multiplier: style.font_size_px / base_font_size,
                    preserve_whitespace: style.preserve_whitespace,
                    link: link.map(|s| s.to_string()),
                });
            }
        } else if child.is_element() {
            let child_style = styles
                .get(child)
                .expect("computed style must exist for every element");
            if child_style.display == super::computed_style::DisplayRole::None {
                continue;
            }

            record_element_anchors(&child, *raw_offset, anchors);

            if super::math::is_math(child) {
                let content = super::math::parse_math(child);
                *raw_offset += content.fallback.chars().count();
                spans.push(TextSpan {
                    text: content.fallback.clone(),
                    math: Some(content),
                    font_family: child_style.font_families.first().cloned(),
                    bold: child_style.bold,
                    italic: child_style.italic,
                    monospace: false,
                    font_size_multiplier: child_style.font_size_px / base_font_size,
                    preserve_whitespace: false,
                    link: link.map(str::to_owned),
                });
                continue;
            }

            match child.tag_name().name() {
                "a" => {
                    let href = child.attribute("href");
                    collect_inline_spans_recursive(
                        &child,
                        base_font_size,
                        href,
                        styles,
                        spans,
                        anchors,
                        raw_offset,
                    );
                }
                _ => {
                    collect_inline_spans_recursive(
                        &child,
                        base_font_size,
                        link,
                        styles,
                        spans,
                        anchors,
                        raw_offset,
                    );
                }
            }
        }
    }
}

/// Merge adjacent spans that have the same formatting.
fn merge_spans(spans: &mut Vec<TextSpan>) {
    let mut i = 0;
    while i + 1 < spans.len() {
        if spans[i].bold == spans[i + 1].bold
            && spans[i].math.is_none()
            && spans[i + 1].math.is_none()
            && spans[i].font_family == spans[i + 1].font_family
            && spans[i].italic == spans[i + 1].italic
            && spans[i].monospace == spans[i + 1].monospace
            && spans[i].font_size_multiplier == spans[i + 1].font_size_multiplier
            && spans[i].preserve_whitespace == spans[i + 1].preserve_whitespace
            && spans[i].link == spans[i + 1].link
        {
            let next_text = spans[i + 1].text.clone();
            spans[i].text.push_str(&next_text);
            spans.remove(i + 1);
        } else {
            i += 1;
        }
    }
}

/// Recursively collect text that participates in native presentation.
fn collect_visible_text_content(
    node: &roxmltree::Node,
    styles: &super::computed_style::ComputedDocumentStyles,
) -> String {
    let mut text = String::new();
    for child in node.children() {
        if child.is_text() {
            text.push_str(child.text().unwrap_or(""));
        } else if child.is_element() {
            let hidden = styles
                .get(child)
                .is_some_and(|style| style.display == super::computed_style::DisplayRole::None);
            if !hidden {
                text.push_str(&collect_visible_text_content(&child, styles));
            }
        }
    }
    text
}

/// Extract a language hint from a `class` attribute.
///
/// Looks for patterns like `language-rust`, `lang-python`, `code-erlang`,
/// `sourceCode erlang`, or bare language names in the class of the element
/// or its first `<code>` child.
fn extract_language_hint(node: &roxmltree::Node) -> Option<String> {
    // Check the node itself and its first <code> child.
    let classes = [
        node.attribute("class"),
        node.children()
            .find(|c| c.is_element() && c.tag_name().name() == "code")
            .and_then(|c| c.attribute("class")),
    ];

    for class_attr in classes.into_iter().flatten() {
        for cls in class_attr.split_whitespace() {
            let lang = cls
                .strip_prefix("language-")
                .or_else(|| cls.strip_prefix("lang-"))
                .or_else(|| cls.strip_prefix("code-"))
                .or_else(|| cls.strip_prefix("sourceCode"));

            if let Some(l) = lang
                && !l.is_empty()
            {
                return Some(l.to_lowercase());
            }
        }
    }

    None
}

/// Resolve a relative path against a base directory.
fn resolve_relative(base: &str, href: &str) -> Option<String> {
    super::CanonicalEpubPath::resolve(base, href)
        .ok()
        .map(|reference| reference.path.as_str().to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chapter_anchors_follow_search_text_character_offsets() {
        let xhtml = r#"<html><body>
            <p>before</p>
            <section id="section"><p id="second">alpha <a name="middle"></a>beta <span id="target">gamma</span></p></section>
            <p><span id="duplicate">first</span></p>
            <p id="duplicate">second</p>
            <p style="display:none" id="hidden">hidden</p>
        </body></html>"#;
        let styles = super::super::style::EpubStyles::default();
        let limits = EpubLimits::default();
        let fonts = super::super::font::EpubFontBook::new(&[], &styles, &HashMap::new(), &limits)
            .expect("empty font book should be valid");
        let parsed = parse_chapter_content_at_path_with_limits(
            xhtml,
            "OPS/chapter.xhtml",
            &styles,
            &fonts,
            &limits,
        )
        .expect("chapter should parse");
        let search_text = crate::search::extract_text_from_nodes(&parsed.nodes);

        assert_eq!(search_text, "before\nalpha beta gamma\nfirst\nsecond\n");
        assert_eq!(parsed.anchor_offsets.get("section"), Some(&7));
        assert_eq!(parsed.anchor_offsets.get("second"), Some(&7));
        assert_eq!(parsed.anchor_offsets.get("middle"), Some(&13));
        assert_eq!(parsed.anchor_offsets.get("target"), Some(&18));
        assert_eq!(parsed.anchor_offsets.get("duplicate"), Some(&24));
        assert!(!parsed.anchor_offsets.contains_key("hidden"));
    }

    #[test]
    fn chapter_anchors_cover_headings_lists_and_table_cells() {
        let xhtml = r#"<html><body>
            <h1><span id="heading">title</span></h1>
            <ul><li id="first-item">one</li><li><span id="second-item">two</span></li></ul>
            <table><tr><td id="cell">cell</td><td>other</td></tr></table>
        </body></html>"#;
        let styles = super::super::style::EpubStyles::default();
        let limits = EpubLimits::default();
        let fonts = super::super::font::EpubFontBook::new(&[], &styles, &HashMap::new(), &limits)
            .expect("empty font book should be valid");
        let parsed = parse_chapter_content_at_path_with_limits(
            xhtml,
            "OPS/chapter.xhtml",
            &styles,
            &fonts,
            &limits,
        )
        .expect("chapter should parse");

        assert_eq!(
            crate::search::extract_text_from_nodes(&parsed.nodes),
            "title\none\ntwo\n\ncell\tother\n\n"
        );
        assert_eq!(parsed.anchor_offsets.get("heading"), Some(&0));
        assert_eq!(parsed.anchor_offsets.get("first-item"), Some(&6));
        assert_eq!(parsed.anchor_offsets.get("second-item"), Some(&10));
        assert_eq!(parsed.anchor_offsets.get("cell"), Some(&15));
    }

    #[test]
    fn paragraph_anchor_offsets_include_promoted_display_separators() {
        let xhtml = r#"<html xmlns:m="http://www.w3.org/1998/Math/MathML"><body>
            <p>before <m:math id="formula" display="block"><m:mfrac><m:mi>a</m:mi><m:mi>b</m:mi></m:mfrac></m:math> after <span id="tail">tail</span></p>
        </body></html>"#;
        let styles = super::super::style::EpubStyles::default();
        let limits = EpubLimits::default();
        let fonts = super::super::font::EpubFontBook::new(&[], &styles, &HashMap::new(), &limits)
            .expect("empty font book should be valid");
        let parsed = parse_chapter_content_at_path_with_limits(
            xhtml,
            "OPS/chapter.xhtml",
            &styles,
            &fonts,
            &limits,
        )
        .expect("chapter should parse");

        assert_eq!(
            crate::search::extract_text_from_nodes(&parsed.nodes),
            "before \n(a)/(b)\n after tail\n"
        );
        assert_eq!(parsed.anchor_offsets.get("formula"), Some(&8));
        assert_eq!(parsed.anchor_offsets.get("tail"), Some(&23));
    }

    #[test]
    fn chapter_anchors_include_body_empty_markers_and_table_descendants() {
        let xhtml = r#"<html><body id="body-top">
            <a id="empty-marker" name="legacy-marker"></a><p id="empty-paragraph"></p>
            <p>before</p>
            <table><caption id="caption"><span id="caption-child">cap</span></caption>
              <tr id="row"><td><span id="cell-child">cell</span></td></tr>
            </table>
        </body></html>"#;
        let styles = super::super::style::EpubStyles::default();
        let limits = EpubLimits::default();
        let fonts = super::super::font::EpubFontBook::new(&[], &styles, &HashMap::new(), &limits)
            .expect("empty font book should be valid");
        let parsed = parse_chapter_content_at_path_with_limits(
            xhtml,
            "OPS/chapter.xhtml",
            &styles,
            &fonts,
            &limits,
        )
        .expect("chapter should parse");

        assert_eq!(
            crate::search::extract_text_from_nodes(&parsed.nodes),
            "before\ncap\ncell\n\n"
        );
        for anchor in [
            "body-top",
            "empty-marker",
            "legacy-marker",
            "empty-paragraph",
        ] {
            assert_eq!(parsed.anchor_offsets.get(anchor), Some(&0), "{anchor}");
        }
        assert_eq!(parsed.anchor_offsets.get("caption"), Some(&7));
        assert_eq!(parsed.anchor_offsets.get("caption-child"), Some(&7));
        assert_eq!(parsed.anchor_offsets.get("row"), Some(&11));
        assert_eq!(parsed.anchor_offsets.get("cell-child"), Some(&11));
    }

    #[test]
    fn test_parse_paragraph() {
        let xhtml = r#"<html><body><p>Hello world</p></body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());
        assert_eq!(nodes.len(), 1);
        match &nodes[0] {
            ContentNode::Paragraph(spans, _) => {
                assert_eq!(spans.len(), 1);
                assert_eq!(spans[0].text, "Hello world");
                assert!(!spans[0].bold);
                assert!(!spans[0].italic);
            }
            other => panic!("expected Paragraph, got {other:?}"),
        }
    }

    #[test]
    fn tables_preserve_caption_groups_headers_spans_and_nested_content() {
        let nodes = parse_chapter_xhtml(
            r##"<html><body><table>
                <caption>Build <em>matrix</em></caption>
                <thead><tr><th id="platform" scope="col" style="width: 15.6%">Platform</th><th scope="col">Status</th></tr></thead>
                <tbody>
                    <tr><th id="linux" scope="row" rowspan="2">Linux</th><td headers="platform linux"><a href="#pass">Pass</a></td></tr>
                    <tr><td colspan="2">Diagram <img src="../images/table.png" alt="table diagram"/></td></tr>
                </tbody>
                <tfoot><tr><td colspan="2">Summary</td></tr></tfoot>
            </table></body></html>"##,
            "OPS/Text",
            &Default::default(),
        );
        let ContentNode::Table {
            caption,
            row_groups,
            ..
        } = &nodes[0]
        else {
            panic!("table must remain semantic");
        };
        assert_eq!(
            caption
                .iter()
                .map(|span| span.text.as_str())
                .collect::<String>(),
            "Build matrix"
        );
        assert!(caption.iter().any(|span| span.italic));
        assert_eq!(
            row_groups
                .iter()
                .map(|group| group.kind)
                .collect::<Vec<_>>(),
            [
                TableRowGroupKind::Head,
                TableRowGroupKind::Body,
                TableRowGroupKind::Foot
            ]
        );
        let platform = &row_groups[0].rows[0].cells[0];
        assert!(platform.header);
        assert_eq!(platform.id.as_deref(), Some("platform"));
        assert_eq!(platform.scope.as_deref(), Some("col"));
        assert_eq!(platform.style.width, Some(NodeWidth::Percent(0.156)));
        let linux = &row_groups[1].rows[0].cells[0];
        assert_eq!(linux.row_span, 2);
        let pass = &row_groups[1].rows[0].cells[1];
        assert_eq!(pass.headers, ["platform", "linux"]);
        assert!(
            matches!(&pass.children[0], ContentNode::Paragraph(spans, _) if
            spans.iter().any(|span| span.link.as_deref() == Some("#pass")))
        );
        let nested = &row_groups[1].rows[1].cells[0];
        assert_eq!(nested.column_span, 2);
        assert!(
            matches!(nested.children.last(), Some(ContentNode::Image { src, alt, .. }) if
            src == "OPS/images/table.png" && alt == "table diagram")
        );

        let searchable = crate::search::extract_text_from_nodes(&nodes);
        assert!(searchable.contains("Build matrix"));
        assert!(searchable.contains("Platform\tStatus"));
        assert!(searchable.contains("Linux\tPass"));
        assert!(searchable.contains("table diagram"));
    }

    #[test]
    fn direct_rows_form_implicit_bodies_and_preserve_rowspan_zero() {
        let nodes = parse_chapter_xhtml(
            r#"<html><body><table><tr><td rowspan="0" colspan="nope">Cell</td></tr></table></body></html>"#,
            "",
            &Default::default(),
        );
        let ContentNode::Table { row_groups, .. } = &nodes[0] else {
            panic!("table must remain semantic");
        };
        assert_eq!(row_groups[0].kind, TableRowGroupKind::Body);
        let cell = &row_groups[0].rows[0].cells[0];
        assert_eq!((cell.row_span, cell.column_span), (0, 1));
    }

    #[test]
    fn table_cells_preserve_source_order_block_boundaries_and_hidden_subtrees() {
        let nodes = parse_chapter_xhtml(
            r#"<html><body><table><tr><td><span>A</span><img src="x.png" alt="X"/><span>B</span><p>C</p><p>D</p><div style="display:none"><img src="secret.png" alt="secret"/></div></td></tr></table></body></html>"#,
            "OPS",
            &Default::default(),
        );

        assert_eq!(
            crate::search::extract_text_from_nodes(&nodes),
            "AXB\nC\nD\n\n"
        );
    }

    #[test]
    fn table_captions_retain_their_own_computed_font_scale() {
        let nodes = parse_chapter_xhtml(
            r#"<html><head><style>caption { font-size: 200%; text-align: right; direction: rtl; }</style></head><body><table><caption>Summary</caption><tr><td>Value</td></tr></table></body></html>"#,
            "",
            &Default::default(),
        );
        let ContentNode::Table {
            caption,
            caption_style,
            ..
        } = &nodes[0]
        else {
            panic!("table must remain semantic");
        };

        assert_eq!(caption[0].font_size_multiplier, 1.0);
        let caption_style = caption_style.as_ref().expect("caption style must survive");
        assert_eq!(caption_style.font_size_multiplier, Some(2.0));
        assert_eq!(
            caption_style.direction,
            super::super::style::TextDirection::Rtl
        );
        assert_eq!(
            caption_style.text_align,
            Some(super::super::style::TextAlignment::Right)
        );
    }

    #[test]
    fn rejected_image_references_preserve_alt_text_without_entering_the_resource_model() {
        let nodes = parse_chapter_xhtml(
            r#"<html><body><img src="https://example.com/remote.png" alt="remote diagram"/></body></html>"#,
            "OPS/Text",
            &Default::default(),
        );

        assert_eq!(
            crate::search::extract_text_from_nodes(&nodes),
            "remote diagram\n"
        );
        assert!(
            !nodes
                .iter()
                .any(|node| matches!(node, ContentNode::Image { .. }))
        );
    }

    #[test]
    fn xhtml_doctype_does_not_hide_epub_chapter_content() {
        let nodes = parse_chapter_xhtml(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>Introduction</h1><p>Visible chapter text.</p></body></html>"#,
            "",
            &Default::default(),
        );

        assert_eq!(
            crate::search::extract_text_from_nodes(&nodes),
            "Introduction\nVisible chapter text.\n"
        );
    }

    #[test]
    fn xhtml_public_doctype_resolves_standard_named_entities_locally() {
        let xhtml = r#"<?xml version="1.0"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml"><body><p>one&nbsp;two &copy; three</p></body></html>"#;
        let nodes =
            parse_chapter_xhtml_with_limits(xhtml, "", &Default::default(), &EpubLimits::default())
                .expect("standard XHTML entities should resolve without fetching the public DTD");

        assert_eq!(
            crate::search::extract_text_from_nodes(&nodes),
            "one\u{a0}two © three\n"
        );
    }

    #[test]
    fn malformed_chapter_returns_a_contextual_parse_error() {
        let error = parse_chapter_xhtml_with_limits(
            "<html><body><p>broken</body></html>",
            "OPS",
            &Default::default(),
            &EpubLimits::default(),
        )
        .expect_err("malformed XHTML must not become an empty chapter");

        assert!(
            error
                .to_string()
                .contains("failed to parse EPUB chapter XHTML")
        );
    }

    #[test]
    fn numeric_table_spans_saturate_at_html_semantic_limits() {
        let nodes = parse_chapter_xhtml(
            r#"<html><body><table><tr><td rowspan="65536" colspan="65536">large</td><td rowspan="oops" colspan="0">initial</td></tr></table></body></html>"#,
            "",
            &Default::default(),
        );
        let ContentNode::Table { row_groups, .. } = &nodes[0] else {
            panic!("table must remain semantic");
        };

        assert_eq!(row_groups[0].rows[0].cells[0].row_span, 65_534);
        assert_eq!(row_groups[0].rows[0].cells[0].column_span, 1_000);
        assert_eq!(row_groups[0].rows[0].cells[1].row_span, 1);
        assert_eq!(row_groups[0].rows[0].cells[1].column_span, 1);
    }

    #[test]
    fn test_parse_heading() {
        let xhtml = r#"<html><head><style>
            h1 { font-style: italic; font-family: monospace; }
            h2 { font-size: 16px; }
        </style></head><body>
            <h1>Title <span style="font-weight: normal">plain</span></h1>
            <h2>Subtitle</h2><h3>Section</h3><h4>Detail</h4>
        </body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());
        assert_eq!(nodes.len(), 4);
        let ContentNode::Heading { spans, style, .. } = &nodes[0] else {
            panic!("expected heading");
        };
        assert_eq!(
            spans
                .iter()
                .map(|span| span.text.as_str())
                .collect::<String>(),
            "Title plain"
        );
        assert!(spans[0].bold, "UA heading weight must reach presentation");
        assert!(spans[0].italic);
        assert!(spans[0].monospace);
        assert!(!spans[1].bold, "nested heading styles must be preserved");
        assert!(style.font_size_multiplier.is_none());
        assert!(
            matches!(&nodes[1], ContentNode::Heading { level: 2, spans, style } if
            spans[0].text == "Subtitle" && style.font_size_multiplier == Some(0.625))
        );
        assert!(
            matches!(&nodes[2], ContentNode::Heading { level: 3, style, .. } if
            style.font_size_multiplier.is_none())
        );
        assert!(
            matches!(&nodes[3], ContentNode::Heading { level: 4, style, .. } if
            style.font_size_multiplier.is_none())
        );
    }

    #[test]
    fn declared_block_direction_reaches_native_presentation() {
        let nodes = parse_chapter_xhtml(
            r#"<html><body><p dir="rtl">English 123 עברית</p></body></html>"#,
            "",
            &Default::default(),
        );
        let ContentNode::Paragraph(_, style) = &nodes[0] else {
            panic!("expected paragraph");
        };

        assert_eq!(style.direction, super::super::style::TextDirection::Rtl);
    }

    #[test]
    fn default_namespace_stylesheets_cannot_hide_xhtml_with_svg_type_selectors() {
        let nodes = parse_chapter_xhtml(
            r#"<html xmlns="http://www.w3.org/1999/xhtml"><head><style>
                @namespace "http://www.w3.org/2000/svg";
                a { display: none; }
            </style></head><body>
                <p><a href="chapter.xhtml">Visible XHTML link</a></p>
                <svg xmlns="http://www.w3.org/2000/svg"><a>SVG link</a></svg>
            </body></html>"#,
            "",
            &Default::default(),
        );

        assert!(
            crate::search::extract_text_from_nodes(&nodes).contains("Visible XHTML link"),
            "unsupported default namespaces must fail soft instead of broadening selectors"
        );
    }

    #[test]
    fn test_parse_bold_italic() {
        let xhtml =
            r#"<html><body><p>Normal <strong>bold</strong> and <em>italic</em></p></body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());
        assert_eq!(nodes.len(), 1);
        match &nodes[0] {
            ContentNode::Paragraph(spans, _) => {
                // "Normal " (plain), "bold" (bold), " and " (plain), "italic" (italic)
                assert!(spans.len() >= 3, "expected at least 3 spans: {spans:?}");
                let bold_span = spans.iter().find(|s| s.bold);
                assert!(bold_span.is_some(), "should have a bold span");
                assert_eq!(bold_span.unwrap().text, "bold");

                let italic_span = spans.iter().find(|s| s.italic);
                assert!(italic_span.is_some(), "should have an italic span");
                assert_eq!(italic_span.unwrap().text, "italic");
            }
            other => panic!("expected Paragraph, got {other:?}"),
        }
    }

    #[test]
    fn test_parse_collapses_xhtml_source_indentation() {
        let xhtml = r#"<html><body><p>Ordinary prose wraps in the source
            but source indentation must <em>not</em> indent rendered lines.
        </p></body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());

        match &nodes[0] {
            ContentNode::Paragraph(spans, _) => {
                let text = spans
                    .iter()
                    .map(|span| span.text.as_str())
                    .collect::<String>();
                assert_eq!(
                    text,
                    "Ordinary prose wraps in the source but source indentation must not indent rendered lines."
                );
                assert_eq!(
                    spans
                        .iter()
                        .find(|span| span.italic)
                        .map(|span| span.text.as_str()),
                    Some("not")
                );
            }
            other => panic!("expected Paragraph, got {other:?}"),
        }
    }

    #[test]
    fn test_parse_preserves_inline_preformatted_whitespace() {
        let xhtml = r#"<html><head><link rel="stylesheet" href="style.css"/></head><body><p>Run <code class="keep">  x
    y</code> now.</p></body></html>"#;
        let styles = super::super::style::EpubStyles::parse([(
            "style.css",
            ".keep { font-family: monospace; white-space: pre; }",
        )]);
        let nodes = parse_chapter_xhtml(xhtml, "", &styles);

        match &nodes[0] {
            ContentNode::Paragraph(spans, _) => {
                let code = spans
                    .iter()
                    .find(|span| span.monospace)
                    .expect("inline code span should be retained");
                assert_eq!(code.text, "  x\n    y");
            }
            other => panic!("expected Paragraph, got {other:?}"),
        }
    }

    #[test]
    fn production_rendering_uses_selector_cascade_inheritance_and_inline_style() {
        let xhtml = r#"<html><head><link rel="stylesheet" href="style.css"/></head><body>
            <article class="chapter">
                <h1>Title</h1>
                <p id="lead" class="note" style="font-style: normal">Lead <span class="big">large</span></p>
                <p class="source-order">Source order</p>
                <p class="hidden">Hidden</p>
            </article>
        </body></html>"#;
        let css = r#"
            article { font-style: italic; font-size: 125%; }
            article > p.note { font-size: 1.2em; text-align: right; }
            #lead { font-weight: bold; font-style: italic; }
            p.note { font-weight: normal !important; }
            .big { font-size: 2em; }
            h1 ~ p.source-order { font-family: monospace; }
            .source-order { text-align: left; }
            .source-order { text-align: center; }
            .hidden { display: none; }
        "#;
        let styles = super::super::style::EpubStyles::parse([("style.css", css)]);

        let nodes = parse_chapter_xhtml(xhtml, "", &styles);

        let ContentNode::Paragraph(lead, lead_style) = &nodes[1] else {
            panic!("expected lead paragraph");
        };
        assert!(!lead[0].bold, "author !important must beat the ID rule");
        assert!(!lead[0].italic, "inline style must beat the author ID rule");
        assert_eq!(
            lead.iter()
                .find(|span| span.text == "large")
                .map(|span| span.font_size_multiplier),
            Some(2.0)
        );
        assert_eq!(
            lead_style.text_align,
            Some(super::super::style::TextAlignment::Right)
        );
        assert_eq!(lead_style.font_size_multiplier, Some(1.5));

        let ContentNode::Paragraph(source_order, source_order_style) = &nodes[2] else {
            panic!("expected source-order paragraph");
        };
        assert!(
            source_order[0].italic,
            "font style must inherit from article"
        );
        assert!(
            source_order[0].monospace,
            "general sibling selector must match"
        );
        assert_eq!(
            source_order_style.text_align,
            Some(super::super::style::TextAlignment::Center)
        );
        assert_eq!(nodes.len(), 3, "display:none content must be omitted");
    }

    #[test]
    fn production_rendering_honors_stylesheet_media_attributes() {
        let xhtml = r#"<html><head>
            <link rel="stylesheet" href="print.css" media="print"/>
            <style media="screen">.target { font-style: italic; }</style>
            <link rel="stylesheet" href="screen.css" media="screen"/>
        </head><body><p class="target">Visible</p></body></html>"#;
        let styles = super::super::style::EpubStyles::parse([
            ("print.css", ".target { display: none; }"),
            (
                "screen.css",
                ".target { font-style: normal; font-weight: bold; }",
            ),
        ]);

        let nodes = parse_chapter_xhtml(xhtml, "", &styles);

        let ContentNode::Paragraph(spans, _) = &nodes[0] else {
            panic!("expected visible paragraph");
        };
        assert!(!spans[0].italic, "later screen stylesheet must win");
        assert!(spans[0].bold);
    }

    #[test]
    fn production_rendering_omits_hidden_body_and_non_paragraph_descendants() {
        let descendant_xhtml = r#"<html><head><style>.hidden { display: none; }</style></head><body>
            <h1>Visible <span class="hidden">heading sentinel</span></h1>
            <pre>Visible <span class="hidden">code sentinel</span></pre>
        </body></html>"#;

        let nodes = parse_chapter_xhtml(descendant_xhtml, "", &Default::default());

        assert!(matches!(&nodes[0], ContentNode::Heading { spans, .. } if
            spans.iter().map(|span| span.text.as_str()).collect::<String>() == "Visible"));
        assert!(matches!(&nodes[1], ContentNode::CodeBlock { code, .. } if code == "Visible"));

        let hidden_body = r#"<html><head><style>body { display: none; }</style></head>
            <body><p>body sentinel</p></body></html>"#;
        assert!(parse_chapter_xhtml(hidden_body, "", &Default::default()).is_empty());
    }

    #[test]
    fn test_parse_lists() {
        let xhtml = r#"<html><body>
            <ul><li>One</li><li>Two</li></ul>
            <ol><li>First</li><li>Second</li></ol>
        </body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());
        assert_eq!(nodes.len(), 2);
        assert!(matches!(&nodes[0], ContentNode::UnorderedList(items) if items.len() == 2));
        assert!(matches!(
            &nodes[1],
            ContentNode::OrderedList { items, start: 1 } if items.len() == 2
        ));
    }

    #[test]
    fn hidden_list_items_are_omitted_from_presentation_and_search_text() {
        let xhtml = r#"<html><head><style>.hidden { display: none; }</style></head><body>
            <ul><li>Visible unordered</li><li class="hidden">Hidden unordered</li></ul>
            <ol><li class="hidden">Hidden ordered</li><li>Visible ordered</li></ol>
        </body></html>"#;

        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());
        let search_text = crate::search::extract_text_from_nodes(&nodes);

        assert!(matches!(&nodes[0], ContentNode::UnorderedList(items) if items.len() == 1));
        assert!(matches!(&nodes[1], ContentNode::OrderedList { items, .. } if items.len() == 1));
        assert!(search_text.contains("Visible unordered"));
        assert!(search_text.contains("Visible ordered"));
        assert!(!search_text.contains("Hidden"));
    }

    #[test]
    fn test_parse_blockquote() {
        let xhtml = r#"<html><body><blockquote><p>Quoted text</p></blockquote></body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());
        assert_eq!(nodes.len(), 1);
        match &nodes[0] {
            ContentNode::BlockQuote {
                children: inner, ..
            } => {
                assert_eq!(inner.len(), 1);
                assert!(matches!(&inner[0], ContentNode::Paragraph(_, _)));
            }
            other => panic!("expected BlockQuote, got {other:?}"),
        }
    }

    #[test]
    fn test_parse_blockquote_style_and_hanging_indent() {
        let xhtml = r#"<html><head><link rel="stylesheet" href="style.css"/></head><body>
            <blockquote class="toc"><p class="entry">Chapter 1</p></blockquote>
        </body></html>"#;
        let styles = super::super::style::EpubStyles::parse([(
            "style.css",
            ".toc { margin-left: 16px; margin-top: 24px; margin-bottom: 32px; } .entry { margin-left: 32px; margin-bottom: 0; text-indent: -32px; }",
        )]);
        let nodes = parse_chapter_xhtml(xhtml, "", &styles);

        match &nodes[0] {
            ContentNode::BlockQuote { children, style } => {
                assert_eq!(style.margin_left_em, Some(1.0));
                assert_eq!(style.block_spacing_em, Some(2.0));
                assert!(matches!(
                    &children[0],
                    ContentNode::Paragraph(_, paragraph_style)
                        if paragraph_style.margin_left_em == Some(0.0)
                            && paragraph_style.block_spacing_em == Some(0.0)
                ));
            }
            other => panic!("expected BlockQuote, got {other:?}"),
        }
    }

    #[test]
    fn test_parse_image() {
        let xhtml = r#"<html><body><img src="images/fig1.png" alt="Figure 1"/></body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "OEBPS", &Default::default());
        assert_eq!(nodes.len(), 1);
        match &nodes[0] {
            ContentNode::Image { src, alt, .. } => {
                assert_eq!(src, "OEBPS/images/fig1.png");
                assert_eq!(alt, "Figure 1");
            }
            other => panic!("expected Image, got {other:?}"),
        }
    }

    #[test]
    fn figure_retains_its_caption_with_the_image() {
        let xhtml = r#"<html><body><figure><div><img src="images/fig1.png" alt="Diagram"/><h6>Figure 1. Architecture</h6></div></figure><p>Following text</p></body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "OEBPS", &Default::default());

        assert_eq!(nodes.len(), 2);
        let ContentNode::Image { caption, .. } = &nodes[0] else {
            panic!("expected retained figure image");
        };
        assert_eq!(
            caption
                .iter()
                .map(|span| span.text.as_str())
                .collect::<String>(),
            "Figure 1. Architecture"
        );
        assert_eq!(
            crate::search::extract_text_from_nodes(&nodes),
            "Diagram\nFigure 1. Architecture\nFollowing text\n"
        );
    }

    #[test]
    fn figure_accepts_caption_before_image_and_preserves_multiblock_content_and_style() {
        let xhtml = r#"<html><head><style>figcaption { text-align: right; font-size: 20px; }</style></head><body>
          <p>Before</p><figure id="figure"><figcaption id="caption"><p>First <em>paragraph</em>.</p><p>Second paragraph.</p></figcaption><img id="image" src="figure.png" alt="Diagram"/></figure><p id="after">After</p>
        </body></html>"#;
        let styles = super::super::style::EpubStyles::default();
        let limits = EpubLimits::default();
        let fonts = super::super::font::EpubFontBook::new(&[], &styles, &HashMap::new(), &limits)
            .expect("empty font book should be valid");
        let parsed = parse_chapter_content_at_path_with_limits(
            xhtml,
            "OPS/chapter.xhtml",
            &styles,
            &fonts,
            &limits,
        )
        .expect("figure should parse");
        let ContentNode::Image {
            caption,
            caption_style,
            ..
        } = &parsed.nodes[1]
        else {
            panic!("figure should produce one semantic image");
        };

        assert_eq!(
            caption
                .iter()
                .map(|span| span.text.as_str())
                .collect::<String>(),
            "First paragraph.\nSecond paragraph."
        );
        assert!(
            caption
                .iter()
                .any(|span| span.text == "paragraph" && span.italic)
        );
        assert_eq!(
            caption_style
                .as_ref()
                .and_then(|style| style.font_size_multiplier),
            Some(1.25)
        );
        assert_eq!(
            caption_style.as_ref().and_then(|style| style.text_align),
            Some(super::super::style::TextAlignment::Right)
        );
        let search = crate::search::extract_text_from_nodes(&parsed.nodes);
        assert_eq!(
            search,
            "Before\nDiagram\nFirst paragraph.\nSecond paragraph.\nAfter\n"
        );
        assert_eq!(parsed.anchor_offsets.get("figure"), Some(&7));
        assert_eq!(parsed.anchor_offsets.get("image"), Some(&7));
        assert_eq!(parsed.anchor_offsets.get("caption"), Some(&15));
        assert_eq!(parsed.anchor_offsets.get("after"), Some(&50));
    }

    #[test]
    fn test_parse_hr() {
        let xhtml = r#"<html><body><hr/></body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());
        assert_eq!(nodes.len(), 1);
        assert!(matches!(&nodes[0], ContentNode::HorizontalRule));
    }

    #[test]
    fn test_parse_div_wrapper() {
        let xhtml = r#"<html><body><div><p>Inside div</p></div></body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());
        assert_eq!(nodes.len(), 1);
        assert!(matches!(&nodes[0], ContentNode::Paragraph(_, _)));
    }

    #[test]
    fn test_parse_pre_code_block() {
        let xhtml = r#"<html><body><pre class="language-rust">fn main() {
    println!("hello");
}</pre></body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());
        assert_eq!(nodes.len(), 1);
        match &nodes[0] {
            ContentNode::CodeBlock { code, language } => {
                assert!(code.contains("fn main()"), "code should contain fn main()");
                assert_eq!(language.as_deref(), Some("rust"));
            }
            other => panic!("expected CodeBlock, got {other:?}"),
        }
    }

    #[test]
    fn test_parse_pre_without_language() {
        let xhtml = r#"<html><body><pre>some plain text</pre></body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());
        assert_eq!(nodes.len(), 1);
        match &nodes[0] {
            ContentNode::CodeBlock { code, language } => {
                assert_eq!(code, "some plain text");
                assert!(language.is_none());
            }
            other => panic!("expected CodeBlock, got {other:?}"),
        }
    }

    #[test]
    fn test_parse_pre_code_nested() {
        let xhtml =
            r#"<html><body><pre><code class="lang-python">print("hi")</code></pre></body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());
        assert_eq!(nodes.len(), 1);
        match &nodes[0] {
            ContentNode::CodeBlock { code, language } => {
                assert!(code.contains("print"));
                assert_eq!(language.as_deref(), Some("python"));
            }
            other => panic!("expected CodeBlock, got {other:?}"),
        }
    }

    #[test]
    fn test_parse_inline_code() {
        let xhtml = r#"<html><body><p>Use <code>println!</code> to print</p></body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());
        assert_eq!(nodes.len(), 1);
        match &nodes[0] {
            ContentNode::Paragraph(spans, _) => {
                let mono_span = spans.iter().find(|s| s.monospace);
                assert!(mono_span.is_some(), "should have a monospace span");
                assert_eq!(mono_span.unwrap().text, "println!");
            }
            other => panic!("expected Paragraph, got {other:?}"),
        }
    }

    #[test]
    fn mathml_blocks_retain_bounded_structure_display_and_search_fallback() {
        let xhtml = r#"<html xmlns="http://www.w3.org/1999/xhtml"><body>
            <math display="block" xmlns="http://www.w3.org/1998/Math/MathML">
                <mroot><mi>x</mi><mn>3</mn></mroot>
            </math>
            <math xmlns="http://www.w3.org/1998/Math/MathML">
                <menclose><mtext>readable fallback</mtext></menclose>
            </math>
        </body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());

        assert!(matches!(
            &nodes[0],
            ContentNode::Math { content, .. }
                if content.display == super::super::MathDisplay::Block
                    && content.expression.is_some()
                    && content.fallback == "root(x, 3)"
        ));
        assert!(matches!(
            &nodes[1],
            ContentNode::Math { content, .. }
                if content.display == super::super::MathDisplay::Inline
                    && content.expression.is_none()
                    && content.fallback == "readable fallback"
        ));
        assert_eq!(
            crate::search::extract_text_from_nodes(&nodes),
            "root(x, 3)\nreadable fallback\n"
        );
    }

    #[test]
    fn paragraphs_retain_inline_math_and_promote_explicit_display_math() {
        let xhtml = r#"<html xmlns="http://www.w3.org/1999/xhtml"><body>
            <p>Area is <math xmlns="http://www.w3.org/1998/Math/MathML">
                <mfrac><mi>a</mi><mi>b</mi></mfrac>
            </math> today.</p>
            <p>before <math display="block" xmlns="http://www.w3.org/1998/Math/MathML">
                <msqrt><mi>x</mi></msqrt>
            </math> after</p>
        </body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());

        assert!(matches!(
            &nodes[0],
            ContentNode::Paragraph(spans, _)
                if spans.len() == 3
                    && spans[0].text == "Area is "
                    && spans[1].text == "(a)/(b)"
                    && spans[1].math.as_ref().is_some_and(|math|
                        math.display == super::super::MathDisplay::Inline
                            && math.expression.is_some())
                    && spans[2].text == " today."
        ));
        assert!(matches!(
            &nodes[2],
            ContentNode::Math { content, .. }
                if content.display == super::super::MathDisplay::Block
                    && content.fallback == "sqrt(x)"
        ));
        assert_eq!(
            crate::search::extract_text_from_nodes(&nodes),
            "Area is (a)/(b) today.\nbefore \nsqrt(x)\n after\n"
        );
    }

    #[test]
    fn unsupported_linked_display_math_retains_block_semantics_and_link() {
        let xhtml = r##"<html xmlns="http://www.w3.org/1999/xhtml"><body>
            <p>before <a href="#proof"><math display="block"
                xmlns="http://www.w3.org/1998/Math/MathML">
                <menclose><mtext>readable display fallback</mtext></menclose>
            </math></a> after</p>
        </body></html>"##;
        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());

        assert_eq!(
            nodes.len(),
            3,
            "display semantics must not depend on native support"
        );
        assert!(matches!(
            &nodes[0],
            ContentNode::Paragraph(spans, _)
                if spans.iter().map(|span| span.text.as_str()).collect::<String>() == "before "
        ));
        assert!(matches!(
            &nodes[1],
            ContentNode::Math { content, .. }
                if content.display == super::super::MathDisplay::Block
                    && content.expression.is_none()
                    && content.fallback == "readable display fallback"
        ));
        assert!(
            format!("{:?}", nodes[1]).contains("#proof"),
            "promoting linked display math must retain its navigation target"
        );
        assert!(matches!(
            &nodes[2],
            ContentNode::Paragraph(spans, _)
                if spans.iter().map(|span| span.text.as_str()).collect::<String>() == " after"
        ));
    }

    #[test]
    fn table_display_math_preserves_block_search_separators() {
        let xhtml = r#"<html xmlns="http://www.w3.org/1999/xhtml"><body>
            <table><tr><td>before<math display="block"
                xmlns="http://www.w3.org/1998/Math/MathML">
                <menclose><mtext>display fallback</mtext></menclose>
            </math>after</td></tr></table>
        </body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());

        assert_eq!(
            crate::search::extract_text_from_nodes(&nodes),
            "before\ndisplay fallback\nafter\n\n",
            "table display blocks must retain the same separators as chapter flow"
        );
        let ContentNode::Table { row_groups, .. } = &nodes[0] else {
            panic!("expected table");
        };
        let cell = &row_groups[0].rows[0].cells[0];
        assert_eq!(cell.block_starts, vec![1, 2]);
    }

    #[test]
    fn preformatted_monospace_css_cannot_bypass_mathml_admission() {
        let xhtml = format!(
            r#"<html xmlns="http://www.w3.org/1999/xhtml"><body>
                <math xmlns="http://www.w3.org/1998/Math/MathML"
                    style="font-family: monospace; white-space: pre"><mi>x</mi></math>
                <math xmlns="http://www.w3.org/1998/Math/MathML"
                    style="font-family: monospace; white-space: pre"><mtext>{}</mtext></math>
            </body></html>"#,
            "x".repeat(1025)
        );
        let nodes = parse_chapter_xhtml(&xhtml, "", &Default::default());

        assert!(matches!(
            &nodes[0],
            ContentNode::Math { content, .. }
                if content.expression.is_some() && content.fallback == "x"
        ));
        assert!(matches!(
            &nodes[1],
            ContentNode::Math { content, .. }
                if content.expression.is_none()
                    && content.fallback == "[math expression omitted]"
        ));
    }

    #[test]
    fn test_parse_link() {
        let xhtml = r#"<html><body><p>Visit <a href="https://example.com">our site</a> today</p></body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());
        assert_eq!(nodes.len(), 1);
        match &nodes[0] {
            ContentNode::Paragraph(spans, _) => {
                let link_span = spans.iter().find(|s| s.link.is_some());
                assert!(link_span.is_some(), "should have a link span");
                let link_span = link_span.unwrap();
                assert_eq!(link_span.text, "our site");
                assert_eq!(link_span.link.as_deref(), Some("https://example.com"));
            }
            other => panic!("expected Paragraph, got {other:?}"),
        }
    }

    #[test]
    fn test_parse_bold_link() {
        let xhtml =
            r#"<html><body><p><a href="url"><strong>bold link</strong></a></p></body></html>"#;
        let nodes = parse_chapter_xhtml(xhtml, "", &Default::default());
        assert_eq!(nodes.len(), 1);
        match &nodes[0] {
            ContentNode::Paragraph(spans, _) => {
                let link_span = spans.iter().find(|s| s.link.is_some());
                assert!(link_span.is_some());
                let link_span = link_span.unwrap();
                assert!(link_span.bold, "link should be bold");
                assert_eq!(link_span.link.as_deref(), Some("url"));
            }
            other => panic!("expected Paragraph, got {other:?}"),
        }
    }
}
