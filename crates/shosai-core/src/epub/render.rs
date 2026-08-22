//! Simplified XHTML → content model renderer for EPUB chapters.
//!
//! Parses EPUB chapter XHTML into a flat list of [`ContentNode`] values that
//! the GUI layer can map to native widgets. A bounded native CSS cascade maps
//! supported computed styles onto block and inline presentation values.

use anyhow::Result;
use std::sync::Arc;

use super::EpubLimits;

/// A styled span of inline text.
#[derive(Debug, Clone, PartialEq)]
pub struct TextSpan {
    pub text: String,
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
    pub children: Vec<ContentNode>,
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
        row_groups: Vec<TableRowGroup>,
        style: NodeStyle,
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
}

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
}

fn parse_chapter_xhtml_with_owner_and_limits(
    xhtml: &str,
    base_path: &str,
    chapter_path: Option<&str>,
    styles: &super::style::EpubStyles,
    fonts: Option<&super::font::EpubFontBook>,
    limits: &EpubLimits,
) -> Result<Vec<ContentNode>> {
    let doc = match roxmltree::Document::parse(xhtml) {
        Ok(d) => d,
        Err(_) => return Ok(Vec::new()),
    };

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
        return Ok(Vec::new());
    }

    Ok(parse_block_children(body, base_path, &computed_styles))
}

/// Parse block-level children of an element.
fn parse_block_children(
    parent: roxmltree::Node,
    base_path: &str,
    styles: &super::computed_style::ComputedDocumentStyles,
) -> Vec<ContentNode> {
    let mut nodes = Vec::new();

    for child in parent.children() {
        if !child.is_element() {
            if child.is_text() {
                let text = child.text().unwrap_or("").trim();
                if !text.is_empty() {
                    nodes.push(ContentNode::Paragraph(
                        vec![TextSpan {
                            text: text.to_string(),
                            font_family: None,
                            bold: false,
                            italic: false,
                            monospace: false,
                            font_size_multiplier: 1.0,
                            preserve_whitespace: false,
                            link: None,
                        }],
                        NodeStyle::default(),
                    ));
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

        // If the CSS says monospace + preserve-whitespace, treat as code block
        // regardless of the HTML tag (handles Calibre-generated classes).
        if !matches!(child.tag_name().name(), "pre" | "code")
            && css_style.monospace
            && css_style.preserve_whitespace
        {
            let code = collect_visible_text_content(&child, styles);
            if !code.trim().is_empty() {
                nodes.push(ContentNode::CodeBlock {
                    code: code.trim().to_string(),
                    language: None,
                });
                continue;
            }
        }

        let node_style = css_to_node_style(css_style, child.tag_name().name());

        match child.tag_name().name() {
            "h1" => push_heading(&mut nodes, &child, 1, &node_style, styles),
            "h2" => push_heading(&mut nodes, &child, 2, &node_style, styles),
            "h3" => push_heading(&mut nodes, &child, 3, &node_style, styles),
            "h4" => push_heading(&mut nodes, &child, 4, &node_style, styles),
            "h5" => push_heading(&mut nodes, &child, 5, &node_style, styles),
            "h6" => push_heading(&mut nodes, &child, 6, &node_style, styles),

            "p" => {
                let spans = collect_inline_spans(&child, styles, css_style.font_size_px);
                if !spans.is_empty() {
                    nodes.push(ContentNode::Paragraph(spans, node_style));
                }
            }

            "blockquote" => {
                let inner = parse_block_children(child, base_path, styles);
                if !inner.is_empty() {
                    nodes.push(ContentNode::BlockQuote {
                        children: inner,
                        style: node_style,
                    });
                }
            }

            "table" => {
                if let Some(table) = parse_table(&child, base_path, styles, node_style) {
                    nodes.push(table);
                }
            }

            "ul" => {
                let items = parse_list_items(&child, styles);
                if !items.is_empty() {
                    nodes.push(ContentNode::UnorderedList(items));
                }
            }

            "ol" => {
                let items = parse_list_items(&child, styles);
                if !items.is_empty() {
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
                    nodes.push(ContentNode::Image {
                        src: resolve_relative(base_path, src),
                        alt,
                    });
                }
            }

            "hr" => {
                nodes.push(ContentNode::HorizontalRule);
            }

            "div" | "section" | "article" | "main" | "aside" | "header" | "footer" | "figure"
            | "figcaption" => {
                nodes.extend(parse_block_children(child, base_path, styles));
            }

            _ => {
                let spans = collect_inline_spans(&child, styles, css_style.font_size_px);
                if !spans.is_empty() {
                    nodes.push(ContentNode::Paragraph(spans, node_style));
                }
            }
        }
    }

    nodes
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
            let base = styles.get(caption).map_or(16.0, |style| style.font_size_px);
            collect_inline_spans(&caption, styles, base)
        })
        .unwrap_or_default();
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
    let mut children = Vec::new();
    let spans = collect_inline_spans(cell, styles, css.font_size_px);
    if !spans.is_empty() {
        children.push(ContentNode::Paragraph(
            spans,
            css_to_node_style(css, cell.tag_name().name()),
        ));
    }
    for image in cell
        .descendants()
        .filter(|node| node.is_element() && node.tag_name().name() == "img")
        .filter(|node| {
            styles
                .get(*node)
                .is_none_or(|style| style.display != super::computed_style::DisplayRole::None)
        })
    {
        if let Some(src) = image.attribute("src") {
            children.push(ContentNode::Image {
                src: resolve_relative(base_path, src),
                alt: image.attribute("alt").unwrap_or("").to_owned(),
            });
        }
    }
    Some(TableCell {
        id: cell.attribute("id").map(str::to_owned),
        header: cell.tag_name().name() == "th",
        scope: cell.attribute("scope").map(str::to_owned),
        headers: cell.attribute("headers").map_or_else(Vec::new, |headers| {
            headers.split_whitespace().map(str::to_owned).collect()
        }),
        row_span: table_span(cell.attribute("rowspan"), true),
        column_span: table_span(cell.attribute("colspan"), false),
        children,
        style: css_to_node_style(css, cell.tag_name().name()),
    })
}

fn table_span(value: Option<&str>, zero_is_valid: bool) -> u16 {
    value
        .and_then(|value| value.parse::<u16>().ok())
        .filter(|value| *value > 0 || zero_is_valid)
        .unwrap_or(1)
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
    }
}

/// Collect heading text content.
fn push_heading(
    nodes: &mut Vec<ContentNode>,
    element: &roxmltree::Node,
    level: u8,
    node_style: &NodeStyle,
    styles: &super::computed_style::ComputedDocumentStyles,
) {
    let font_size = styles
        .get(*element)
        .expect("computed style must exist for heading")
        .font_size_px;
    let spans = collect_inline_spans(element, styles, font_size);
    if !spans.is_empty() {
        nodes.push(ContentNode::Heading {
            level,
            spans,
            style: node_style.clone(),
        });
    }
}

/// Parse <li> items from a <ul> or <ol>.
fn parse_list_items(
    list: &roxmltree::Node,
    styles: &super::computed_style::ComputedDocumentStyles,
) -> Vec<Vec<TextSpan>> {
    let mut items = Vec::new();
    for child in list.children() {
        if child.is_element() && child.tag_name().name() == "li" {
            if styles
                .get(child)
                .is_some_and(|style| style.display == super::computed_style::DisplayRole::None)
            {
                continue;
            }
            let spans = collect_inline_spans(&child, styles, 16.0);
            if !spans.is_empty() {
                items.push(spans);
            }
        }
    }
    items
}

/// Collect inline text spans with bold/italic formatting from an element.
fn collect_inline_spans(
    element: &roxmltree::Node,
    styles: &super::computed_style::ComputedDocumentStyles,
    base_font_size: f32,
) -> Vec<TextSpan> {
    let mut spans = Vec::new();
    collect_inline_spans_recursive(element, base_font_size, None, styles, &mut spans);

    // XHTML follows HTML whitespace rules for normal inline content: source
    // line breaks and indentation collapse to a single space. Preserve raw
    // whitespace only in code blocks, which do not use this collector.
    collapse_inline_whitespace(&mut spans);

    // Merge adjacent spans with the same formatting.
    merge_spans(&mut spans);
    spans
}

fn collapse_inline_whitespace(spans: &mut Vec<TextSpan>) {
    let mut at_start_or_whitespace = true;
    for span in spans.iter_mut() {
        if span.preserve_whitespace {
            at_start_or_whitespace = span
                .text
                .chars()
                .last()
                .is_none_or(|character| character.is_ascii_whitespace());
            continue;
        }
        let mut normalized = String::with_capacity(span.text.len());
        for character in span.text.chars() {
            if character.is_ascii_whitespace() {
                if !at_start_or_whitespace {
                    normalized.push(' ');
                    at_start_or_whitespace = true;
                }
            } else {
                normalized.push(character);
                at_start_or_whitespace = false;
            }
        }
        span.text = normalized;
    }

    if let Some(last) = spans
        .iter_mut()
        .rfind(|span| !span.text.is_empty() && !span.preserve_whitespace)
        && last.text.ends_with(' ')
    {
        last.text.pop();
    }
    spans.retain(|span| !span.text.is_empty());
}

fn collect_inline_spans_recursive(
    node: &roxmltree::Node,
    base_font_size: f32,
    link: Option<&str>,
    styles: &super::computed_style::ComputedDocumentStyles,
    spans: &mut Vec<TextSpan>,
) {
    let style = styles
        .get(*node)
        .expect("computed style must exist for every element");
    for child in node.children() {
        if child.is_text() {
            let text = child.text().unwrap_or("");
            if !text.is_empty() {
                spans.push(TextSpan {
                    text: text.to_string(),
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

            match child.tag_name().name() {
                "a" => {
                    let href = child.attribute("href");
                    collect_inline_spans_recursive(&child, base_font_size, href, styles, spans);
                }
                _ => {
                    collect_inline_spans_recursive(&child, base_font_size, link, styles, spans);
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
fn resolve_relative(base: &str, href: &str) -> String {
    super::CanonicalEpubPath::resolve(base, href).map_or_else(
        |_| href.to_owned(),
        |reference| reference.path.as_str().to_owned(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

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
                <thead><tr><th id="platform" scope="col">Platform</th><th scope="col">Status</th></tr></thead>
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
            matches!(nested.children.last(), Some(ContentNode::Image { src, alt }) if
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
            ".toc { margin-left: 16px; } .entry { margin-left: 32px; text-indent: -32px; }",
        )]);
        let nodes = parse_chapter_xhtml(xhtml, "", &styles);

        match &nodes[0] {
            ContentNode::BlockQuote { children, style } => {
                assert_eq!(style.margin_left_em, Some(1.0));
                assert!(matches!(
                    &children[0],
                    ContentNode::Paragraph(_, paragraph_style)
                        if paragraph_style.margin_left_em == Some(0.0)
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
            ContentNode::Image { src, alt } => {
                assert_eq!(src, "OEBPS/images/fig1.png");
                assert_eq!(alt, "Figure 1");
            }
            other => panic!("expected Image, got {other:?}"),
        }
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
