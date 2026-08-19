//! EPUB-specific pagination models and pure page geometry helpers.

use iced::Size;
use shosai_core::epub::render::ContentNode;

pub(crate) const BLOCKQUOTE_SPACING: f32 = 8.0;
pub(crate) const TEXT_LINE_HEIGHT: f32 = 1.2;
pub(crate) const AVERAGE_CHARACTER_WIDTH: f32 = 0.55;
pub(crate) const MAX_CHARACTERS_PER_LINE: usize = 72;
pub(crate) const PAGE_NUMBER_SIZE: f32 = 11.0;

#[derive(Debug, Clone)]
pub(crate) struct PageNode {
    pub(crate) node: ContentNode,
    pub(crate) text_offset: usize,
}

pub(crate) type PageNodes = Vec<PageNode>;

#[derive(Debug, Clone)]
pub(crate) struct Page {
    pub(crate) chapter: usize,
    pub(crate) title: Option<String>,
    pub(crate) nodes: PageNodes,
}

pub(crate) fn page_size(
    available: Size,
    spread: bool,
    gutter: f32,
    font_size: f32,
    line_spacing: f32,
) -> Size {
    let page_count = if spread { 2.0 } else { 1.0 };
    let available_text_width =
        ((available.width - gutter * (page_count - 1.0)) / page_count - 40.0).max(120.0);
    let readable_text_width = font_size * AVERAGE_CHARACTER_WIDTH * MAX_CHARACTERS_PER_LINE as f32;
    let footer_height = PAGE_NUMBER_SIZE * TEXT_LINE_HEIGHT + font_size * line_spacing;
    Size::new(
        available_text_width.min(readable_text_width),
        (available.height - 40.0 - footer_height).max(120.0),
    )
}

pub(crate) fn spread_start(page: usize, page_count: usize, spread: bool) -> usize {
    let page = page.min(page_count.saturating_sub(1));
    if spread { page - page % 2 } else { page }
}

pub(crate) fn visible_pages(page: usize, page_count: usize, spread: bool) -> Vec<usize> {
    if page_count == 0 {
        return Vec::new();
    }
    let start = spread_start(page, page_count, spread);
    let end = if spread {
        (start + 1).min(page_count - 1)
    } else {
        start
    };
    (start..=end).collect()
}

pub(crate) fn paginate_epub_chapter(
    nodes: &[ContentNode],
    title: Option<&str>,
    font_size: f32,
    line_spacing: f32,
    page_size: Size,
) -> Vec<PageNodes> {
    let chars_per_line = (page_size.width / (font_size * AVERAGE_CHARACTER_WIDTH).max(1.0))
        .floor()
        .max(12.0) as usize;
    let block_spacing = (font_size * line_spacing).max(1.0);
    let lines_per_page = (page_size.height / block_spacing).floor().max(4.0) as usize;
    let first_page_has_title = title.is_some();
    let title_height = title
        .map(|title| {
            let title_chars_per_line = scaled_characters_per_line(chars_per_line, 1.5);
            title.chars().count().div_ceil(title_chars_per_line).max(1) as f32
                * font_size
                * 1.5
                * TEXT_LINE_HEIGHT
                + block_spacing
        })
        .unwrap_or(0.0);
    let mut pages = vec![Vec::new()];
    let mut remaining = (page_size.height - title_height).max(0.0);
    let mut text_offset = 0;

    for (node_index, node) in nodes.iter().enumerate() {
        let keep_with_next = match node {
            ContentNode::Heading { .. } => true,
            ContentNode::Paragraph(spans, _) => spans.iter().any(|span| span.link.is_some()),
            _ => false,
        };
        if page_has_content(&pages, first_page_has_title)
            && keep_with_next
            && let Some(ContentNode::BlockQuote { children, .. }) = nodes.get(node_index + 1)
            && let Some(first_child) = children.first()
        {
            let node_height = estimated_epub_node_height(
                node,
                chars_per_line,
                lines_per_page,
                font_size,
                line_spacing,
            );
            let first_child_height = estimated_epub_compact_node_height(
                first_child,
                chars_per_line,
                lines_per_page,
                font_size,
            );
            if node_height + first_child_height > remaining {
                pages.push(Vec::new());
                remaining = page_size.height;
            }
        }

        let text_len = content_node_text_len(node);
        match node {
            ContentNode::Paragraph(spans, style) => {
                let mut consumed = 0;
                let style_scale = style.font_size_multiplier.unwrap_or(1.0);
                let text_line_height = font_size * TEXT_LINE_HEIGHT * style_scale;
                let paragraph_chars_per_line =
                    scaled_characters_per_line(chars_per_line, style_scale);
                while consumed < text_len {
                    if remaining < text_line_height + block_spacing
                        && page_has_content(&pages, first_page_has_title)
                    {
                        pages.push(Vec::new());
                        remaining = page_size.height;
                    }
                    let available_lines = ((remaining - block_spacing).max(text_line_height)
                        / text_line_height)
                        .floor()
                        .max(1.0) as usize;
                    let available_chars = paragraph_chars_per_line * available_lines;
                    let take = epub_span_split_length(spans, consumed, available_chars);
                    let chunk = slice_epub_spans(spans, consumed, take);
                    let chunk_height = take.div_ceil(paragraph_chars_per_line).max(1) as f32
                        * text_line_height
                        + block_spacing;
                    pages.last_mut().unwrap().push(PageNode {
                        node: ContentNode::Paragraph(chunk, style.clone()),
                        text_offset: text_offset + consumed,
                    });
                    remaining = (remaining - chunk_height).max(0.0);
                    consumed += take;
                }
            }
            ContentNode::CodeBlock { code, language } => {
                let mut consumed = 0;
                let code_line_height = font_size * TEXT_LINE_HEIGHT * 0.85;
                let code_padding = 24.0;
                while consumed < text_len {
                    if remaining < code_line_height + code_padding + block_spacing
                        && page_has_content(&pages, first_page_has_title)
                    {
                        pages.push(Vec::new());
                        remaining = page_size.height;
                    }
                    let available_lines = ((remaining - code_padding - block_spacing)
                        .max(code_line_height)
                        / code_line_height)
                        .floor()
                        .max(1.0) as usize;
                    let chunk = code
                        .chars()
                        .skip(consumed)
                        .collect::<String>()
                        .split_inclusive('\n')
                        .take(available_lines)
                        .collect::<String>();
                    let chunk_len = chunk.chars().count();
                    let chunk_height = chunk.lines().count().max(1) as f32 * code_line_height
                        + code_padding
                        + block_spacing;
                    pages.last_mut().unwrap().push(PageNode {
                        node: ContentNode::CodeBlock {
                            code: chunk,
                            language: language.clone(),
                        },
                        text_offset: text_offset + consumed,
                    });
                    remaining = (remaining - chunk_height).max(0.0);
                    consumed += chunk_len;
                }
            }
            ContentNode::UnorderedList(items) => paginate_epub_list(
                items,
                None,
                text_offset,
                chars_per_line,
                font_size,
                line_spacing,
                page_size.height,
                first_page_has_title,
                &mut pages,
                &mut remaining,
            ),
            ContentNode::OrderedList { items, start } => paginate_epub_list(
                items,
                Some(*start),
                text_offset,
                chars_per_line,
                font_size,
                line_spacing,
                page_size.height,
                first_page_has_title,
                &mut pages,
                &mut remaining,
            ),
            ContentNode::BlockQuote { children, style } => {
                let node_height = estimated_epub_node_height(
                    node,
                    chars_per_line,
                    lines_per_page,
                    font_size,
                    line_spacing,
                );
                let follows_linked_label = nodes
                    .get(..node_index)
                    .and_then(|previous| previous.last())
                    .is_some_and(|previous| match previous {
                        ContentNode::Heading { .. } => true,
                        ContentNode::Paragraph(spans, _) => {
                            spans.iter().any(|span| span.link.is_some())
                        }
                        _ => false,
                    });
                let split_after_label = follows_linked_label
                    && node_height > remaining
                    && page_has_content(&pages, first_page_has_title);
                if node_height <= page_size.height && !split_after_label {
                    if node_height > remaining && page_has_content(&pages, first_page_has_title) {
                        pages.push(Vec::new());
                        remaining = page_size.height;
                    }
                    pages.last_mut().unwrap().push(PageNode {
                        node: node.clone(),
                        text_offset,
                    });
                    remaining = (remaining - node_height).max(0.0);
                } else {
                    let available_height = (remaining - block_spacing).max(0.0);
                    let (prefix, remaining_children, prefix_height, prefix_text_len) =
                        if !page_has_content(&pages, first_page_has_title) {
                            (Vec::new(), children.to_vec(), 0.0, 0)
                        } else {
                            split_epub_blockquote_prefix(
                                children,
                                available_height,
                                chars_per_line,
                                lines_per_page,
                                font_size,
                            )
                        };
                    if !prefix.is_empty() {
                        pages.last_mut().unwrap().push(PageNode {
                            node: ContentNode::BlockQuote {
                                children: prefix,
                                style: style.clone(),
                            },
                            text_offset,
                        });
                        remaining = (remaining - prefix_height - block_spacing).max(0.0);
                    }

                    if !remaining_children.is_empty() {
                        if page_has_content(&pages, first_page_has_title) {
                            pages.push(Vec::new());
                        }
                        let child_pages = paginate_epub_chapter(
                            &remaining_children,
                            None,
                            font_size,
                            line_spacing,
                            page_size,
                        );
                        for (index, child_page) in child_pages.into_iter().enumerate() {
                            if index > 0 {
                                pages.push(Vec::new());
                            }
                            let child_offset =
                                child_page.first().map_or(0, |node| node.text_offset);
                            pages.last_mut().unwrap().push(PageNode {
                                node: ContentNode::BlockQuote {
                                    children: child_page
                                        .into_iter()
                                        .map(|node| node.node)
                                        .collect(),
                                    style: style.clone(),
                                },
                                text_offset: text_offset + prefix_text_len + child_offset,
                            });
                        }
                        remaining = 0.0;
                    }
                }
            }
            ContentNode::Image { .. } => {
                if page_has_content(&pages, first_page_has_title) {
                    pages.push(Vec::new());
                }
                pages.last_mut().unwrap().push(PageNode {
                    node: node.clone(),
                    text_offset,
                });
                remaining = 0.0;
            }
            _ => {
                let node_height = estimated_epub_node_height(
                    node,
                    chars_per_line,
                    lines_per_page,
                    font_size,
                    line_spacing,
                );
                if node_height > remaining && page_has_content(&pages, first_page_has_title) {
                    pages.push(Vec::new());
                    remaining = page_size.height;
                }
                pages.last_mut().unwrap().push(PageNode {
                    node: node.clone(),
                    text_offset,
                });
                remaining = (remaining - node_height).max(0.0);
            }
        }
        text_offset += text_len + 1;
    }

    if pages.len() > 1 && pages.last().is_some_and(Vec::is_empty) {
        pages.pop();
    }
    pages
}

fn scaled_characters_per_line(chars_per_line: usize, scale: f32) -> usize {
    ((chars_per_line as f32 / scale.max(0.1)).floor() as usize).max(1)
}

fn page_has_content(pages: &[PageNodes], first_page_has_title: bool) -> bool {
    pages.last().is_some_and(|page| !page.is_empty()) || (first_page_has_title && pages.len() == 1)
}

#[allow(clippy::too_many_arguments)]
fn paginate_epub_list(
    items: &[Vec<shosai_core::epub::render::TextSpan>],
    ordered_start: Option<usize>,
    text_offset: usize,
    chars_per_line: usize,
    font_size: f32,
    line_spacing: f32,
    page_height: f32,
    first_page_has_title: bool,
    pages: &mut Vec<PageNodes>,
    remaining: &mut f32,
) {
    let mut consumed_items = 0;
    let mut consumed_text = 0;
    let text_line_height = font_size * TEXT_LINE_HEIGHT;
    let block_spacing = font_size * line_spacing;

    while consumed_items < items.len() {
        if *remaining < text_line_height + block_spacing
            && page_has_content(pages, first_page_has_title)
        {
            pages.push(Vec::new());
            *remaining = page_height;
        }

        let available_height = (*remaining - block_spacing).max(text_line_height);
        let mut chunk_height = 0.0;
        let mut take = 0;
        for item in &items[consumed_items..] {
            let item_lines = (spans_text_len(item) + 4).div_ceil(chars_per_line).max(1);
            let item_spacing = if take == 0 { 0.0 } else { 4.0 };
            let item_height = item_lines as f32 * text_line_height;
            if take > 0 && chunk_height + item_spacing + item_height > available_height {
                break;
            }
            if take == 0
                && item_height > available_height
                && page_has_content(pages, first_page_has_title)
            {
                break;
            }
            chunk_height += item_spacing + item_height;
            take += 1;
        }

        if take == 0 {
            pages.push(Vec::new());
            *remaining = page_height;
            continue;
        }

        let chunk = items[consumed_items..consumed_items + take].to_vec();
        let node = match ordered_start {
            Some(start) => ContentNode::OrderedList {
                items: chunk,
                start: start + consumed_items,
            },
            None => ContentNode::UnorderedList(chunk),
        };
        pages.last_mut().unwrap().push(PageNode {
            node,
            text_offset: text_offset + consumed_text,
        });
        *remaining = (*remaining - chunk_height - block_spacing).max(0.0);
        consumed_text += items[consumed_items..consumed_items + take]
            .iter()
            .map(|item| spans_text_len(item) + 1)
            .sum::<usize>();
        consumed_items += take;
    }
}

fn epub_span_split_length(
    spans: &[shosai_core::epub::render::TextSpan],
    start: usize,
    maximum: usize,
) -> usize {
    let remaining = spans_text_len(spans).saturating_sub(start);
    if remaining <= maximum {
        return remaining;
    }
    let window = spans
        .iter()
        .flat_map(|span| span.text.chars())
        .skip(start)
        .take(maximum)
        .collect::<Vec<_>>();
    window
        .iter()
        .rposition(|character| character.is_whitespace())
        .map(|index| index + 1)
        .filter(|length| *length >= maximum / 2)
        .unwrap_or(maximum)
}

fn slice_epub_spans(
    spans: &[shosai_core::epub::render::TextSpan],
    start: usize,
    length: usize,
) -> Vec<shosai_core::epub::render::TextSpan> {
    let end = start + length;
    let mut offset = 0;
    spans
        .iter()
        .filter_map(|span| {
            let span_len = span.text.chars().count();
            let local_start = start.saturating_sub(offset).min(span_len);
            let local_end = end.saturating_sub(offset).min(span_len);
            offset += span_len;
            (local_start < local_end).then(|| {
                let mut sliced = span.clone();
                sliced.text = span
                    .text
                    .chars()
                    .skip(local_start)
                    .take(local_end - local_start)
                    .collect();
                sliced
            })
        })
        .collect()
}

fn estimated_epub_node_height(
    node: &ContentNode,
    chars_per_line: usize,
    lines_per_page: usize,
    font_size: f32,
    line_spacing: f32,
) -> f32 {
    estimated_epub_compact_node_height(node, chars_per_line, lines_per_page, font_size)
        + font_size * line_spacing
}

fn estimated_epub_blockquote_height(
    children: &[ContentNode],
    chars_per_line: usize,
    lines_per_page: usize,
    font_size: f32,
) -> f32 {
    children
        .iter()
        .map(|child| {
            estimated_epub_compact_node_height(child, chars_per_line, lines_per_page, font_size)
        })
        .sum::<f32>()
        + BLOCKQUOTE_SPACING * children.len().saturating_sub(1) as f32
}

fn split_epub_blockquote_prefix(
    children: &[ContentNode],
    available_height: f32,
    chars_per_line: usize,
    lines_per_page: usize,
    font_size: f32,
) -> (Vec<ContentNode>, Vec<ContentNode>, f32, usize) {
    let mut prefix = Vec::new();
    let mut prefix_height = 0.0;
    let mut consumed_text = 0;
    for (index, child) in children.iter().enumerate() {
        let spacing = if prefix.is_empty() {
            0.0
        } else {
            BLOCKQUOTE_SPACING
        };
        let child_height =
            estimated_epub_compact_node_height(child, chars_per_line, lines_per_page, font_size);
        if prefix_height + spacing + child_height <= available_height {
            prefix.push(child.clone());
            prefix_height += spacing + child_height;
            consumed_text += content_node_text_len(child) + 1;
            continue;
        }

        if let ContentNode::BlockQuote {
            children: nested_children,
            style,
        } = child
        {
            let nested_available = available_height - prefix_height - spacing;
            if nested_available > 0.0 {
                let (nested_prefix, nested_remaining, nested_height, nested_consumed_text) =
                    split_epub_blockquote_prefix(
                        nested_children,
                        nested_available,
                        chars_per_line,
                        lines_per_page,
                        font_size,
                    );
                if !nested_prefix.is_empty() {
                    prefix.push(ContentNode::BlockQuote {
                        children: nested_prefix,
                        style: style.clone(),
                    });
                    prefix_height += spacing + nested_height;
                    let mut remaining = Vec::new();
                    if !nested_remaining.is_empty() {
                        remaining.push(ContentNode::BlockQuote {
                            children: nested_remaining,
                            style: style.clone(),
                        });
                    }
                    remaining.extend_from_slice(&children[index + 1..]);
                    return (
                        prefix,
                        remaining,
                        prefix_height,
                        consumed_text + nested_consumed_text,
                    );
                }
            }
        }

        if let ContentNode::Paragraph(spans, style) = child {
            let paragraph_available = available_height - prefix_height - spacing;
            let style_scale = style.font_size_multiplier.unwrap_or(1.0);
            let line_height = font_size * TEXT_LINE_HEIGHT * style_scale;
            let paragraph_chars_per_line = scaled_characters_per_line(chars_per_line, style_scale);
            let available_lines = (paragraph_available / line_height).floor().max(0.0) as usize;
            let maximum = paragraph_chars_per_line * available_lines;
            let text_len = spans_text_len(spans);
            let take = epub_span_split_length(spans, 0, maximum);
            if take > 0 && take < text_len {
                let prefix_spans = slice_epub_spans(spans, 0, take);
                let remaining_spans = slice_epub_spans(spans, take, text_len - take);
                prefix.push(ContentNode::Paragraph(prefix_spans, style.clone()));
                let paragraph_height =
                    take.div_ceil(paragraph_chars_per_line).max(1) as f32 * line_height;
                prefix_height += spacing + paragraph_height;
                let mut remaining = vec![ContentNode::Paragraph(remaining_spans, style.clone())];
                remaining.extend_from_slice(&children[index + 1..]);
                return (prefix, remaining, prefix_height, consumed_text + take);
            }
        }

        return (
            prefix,
            children[index..].to_vec(),
            prefix_height,
            consumed_text,
        );
    }

    (prefix, Vec::new(), prefix_height, consumed_text)
}

fn estimated_epub_compact_node_height(
    node: &ContentNode,
    chars_per_line: usize,
    lines_per_page: usize,
    font_size: f32,
) -> f32 {
    let wrapped = |characters: usize, scale: f32| {
        characters
            .div_ceil(scaled_characters_per_line(chars_per_line, scale))
            .max(1) as f32
    };
    let text_line_height = font_size * TEXT_LINE_HEIGHT;
    match node {
        ContentNode::Heading {
            text, level, style, ..
        } => {
            let heading_scale = match level {
                1 => 2.0,
                2 => 1.6,
                3 => 1.3,
                4 => 1.1,
                _ => 1.0,
            };
            let style_scale = style.font_size_multiplier.unwrap_or(1.0);
            let scale = heading_scale * style_scale;
            wrapped(text.chars().count(), scale) * text_line_height * scale
        }
        ContentNode::BlockQuote { children, .. } => {
            estimated_epub_blockquote_height(children, chars_per_line, lines_per_page, font_size)
        }
        ContentNode::UnorderedList(items) | ContentNode::OrderedList { items, .. } => {
            items
                .iter()
                .map(|item| wrapped(spans_text_len(item) + 4, 1.0) * text_line_height)
                .sum::<f32>()
                + 4.0 * items.len().saturating_sub(1) as f32
        }
        ContentNode::CodeBlock { code, .. } => {
            code.lines().count().max(1) as f32 * text_line_height * 0.85 + 24.0
        }
        ContentNode::InlineCode(code) => {
            wrapped(code.chars().count(), 0.9) * text_line_height * 0.9
        }
        ContentNode::Image { .. } => {
            (lines_per_page / 2).max(4) as f32 * font_size * TEXT_LINE_HEIGHT
        }
        ContentNode::HorizontalRule => text_line_height,
        ContentNode::Paragraph(spans, style) => {
            let scale = style.font_size_multiplier.unwrap_or(1.0);
            wrapped(spans_text_len(spans), scale) * text_line_height * scale
        }
    }
}

pub(crate) fn spans_text_len(spans: &[shosai_core::epub::render::TextSpan]) -> usize {
    spans.iter().map(|span| span.text.chars().count()).sum()
}

pub(crate) fn content_node_text_len(node: &ContentNode) -> usize {
    match node {
        ContentNode::Heading { text, .. } => text.chars().count(),
        ContentNode::Paragraph(spans, _) => spans_text_len(spans),
        ContentNode::BlockQuote { children, .. } => children
            .iter()
            .map(|child| content_node_text_len(child) + 1)
            .sum(),
        ContentNode::UnorderedList(items) | ContentNode::OrderedList { items, .. } => {
            items.iter().map(|spans| spans_text_len(spans) + 1).sum()
        }
        ContentNode::CodeBlock { code, .. } | ContentNode::InlineCode(code) => code.chars().count(),
        ContentNode::Image { alt, .. } => alt.chars().count(),
        ContentNode::HorizontalRule => 0,
    }
}

#[cfg(test)]
mod text_layout;

#[cfg(test)]
mod text_shaping;

#[cfg(test)]
mod table_layout;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn epub_paginator_splits_long_paragraphs_without_losing_formatting() {
        let text = "This is a linked sentence that should wrap cleanly. ".repeat(30);
        let spans = vec![shosai_core::epub::render::TextSpan {
            text: text.clone(),
            bold: true,
            italic: false,
            monospace: false,
            preserve_whitespace: false,
            link: Some("chapter-2.xhtml".to_string()),
        }];
        let pages = paginate_epub_chapter(
            &[ContentNode::Paragraph(spans, Default::default())],
            None,
            16.0,
            1.6,
            Size::new(240.0, 180.0),
        );

        assert!(pages.len() > 1);
        let chunks = pages
            .iter()
            .flatten()
            .map(|page_node| match &page_node.node {
                ContentNode::Paragraph(spans, _) => &spans[0],
                node => panic!("expected paragraph, got {node:?}"),
            })
            .collect::<Vec<_>>();
        assert_eq!(
            chunks
                .iter()
                .flat_map(|span| span.text.chars())
                .collect::<String>(),
            text
        );
        assert!(chunks.iter().all(|span| span.bold));
        assert!(
            chunks
                .iter()
                .all(|span| span.link.as_deref() == Some("chapter-2.xhtml"))
        );
    }

    #[test]
    fn epub_paginator_splits_long_lists_without_losing_items() {
        let items = (0..30)
            .map(|index| {
                vec![shosai_core::epub::render::TextSpan {
                    text: format!("List item {index}"),
                    bold: false,
                    italic: false,
                    monospace: false,
                    preserve_whitespace: false,
                    link: None,
                }]
            })
            .collect::<Vec<_>>();
        let pages = paginate_epub_chapter(
            &[ContentNode::OrderedList {
                items: items.clone(),
                start: 1,
            }],
            None,
            16.0,
            1.6,
            Size::new(240.0, 180.0),
        );

        assert!(pages.len() > 1, "a long list must span multiple pages");
        let paginated_items = pages
            .iter()
            .flatten()
            .flat_map(|page_node| match &page_node.node {
                ContentNode::OrderedList { items, .. } => items.clone(),
                node => panic!("expected ordered list, got {node:?}"),
            })
            .collect::<Vec<_>>();
        assert_eq!(paginated_items, items);
        let starts = pages
            .iter()
            .flatten()
            .filter_map(|page_node| match &page_node.node {
                ContentNode::OrderedList { start, .. } => Some(*start),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert!(starts.windows(2).all(|pair| pair[0] < pair[1]));
    }

    #[test]
    fn epub_paginator_keeps_sparse_blockquotes_on_the_same_page() {
        let paragraph = |text: &str| {
            ContentNode::Paragraph(
                vec![shosai_core::epub::render::TextSpan {
                    text: text.to_string(),
                    bold: false,
                    italic: false,
                    monospace: false,
                    preserve_whitespace: false,
                    link: Some(format!("{}.xhtml", text.replace(' ', "-"))),
                }],
                Default::default(),
            )
        };
        let nodes = vec![
            paragraph("Chapter 1"),
            ContentNode::BlockQuote {
                children: vec![paragraph("Section 1.1")],
                style: Default::default(),
            },
            ContentNode::BlockQuote {
                children: vec![paragraph("Section 1.2")],
                style: Default::default(),
            },
        ];

        let pages = paginate_epub_chapter(&nodes, None, 16.0, 1.6, Size::new(240.0, 180.0));

        assert_eq!(pages.len(), 1, "short TOC groups should share a page");
        assert_eq!(pages[0].len(), nodes.len());
    }

    #[test]
    fn epub_paginator_accounts_for_text_height_separately_from_block_spacing() {
        let nodes = (1..=4)
            .map(|index| {
                ContentNode::Paragraph(
                    vec![shosai_core::epub::render::TextSpan {
                        text: format!("Short paragraph {index}"),
                        bold: false,
                        italic: false,
                        monospace: false,
                        preserve_whitespace: false,
                        link: None,
                    }],
                    Default::default(),
                )
            })
            .collect::<Vec<_>>();

        let pages = paginate_epub_chapter(&nodes, None, 16.0, 1.6, Size::new(240.0, 180.0));

        assert_eq!(pages.len(), 1);
        assert_eq!(pages[0].len(), nodes.len());
    }

    #[test]
    fn epub_paginator_packs_sparse_blockquotes_until_the_page_is_full() {
        let nodes = (1..=5)
            .map(|index| ContentNode::BlockQuote {
                children: vec![ContentNode::Paragraph(
                    vec![shosai_core::epub::render::TextSpan {
                        text: format!("Section 1.{index}"),
                        bold: false,
                        italic: false,
                        monospace: false,
                        preserve_whitespace: false,
                        link: Some(format!("section-{index}.xhtml")),
                    }],
                    Default::default(),
                )],
                style: Default::default(),
            })
            .collect::<Vec<_>>();

        let pages = paginate_epub_chapter(&nodes, None, 16.0, 1.6, Size::new(240.0, 180.0));

        assert_eq!(pages.len(), 2, "TOC groups should flow by page capacity");
        assert_eq!(pages[0].len(), 4);
        assert_eq!(pages[1].len(), 1);
        assert_eq!(pages.iter().map(Vec::len).sum::<usize>(), nodes.len());
    }

    #[test]
    fn epub_paginator_keeps_nested_toc_chapter_together_when_it_fits() {
        let paragraph = |text: String| {
            ContentNode::Paragraph(
                vec![shosai_core::epub::render::TextSpan {
                    link: Some(format!("{}.xhtml", text.replace(' ', "-"))),
                    text,
                    bold: false,
                    italic: false,
                    monospace: false,
                    preserve_whitespace: false,
                }],
                Default::default(),
            )
        };
        let subsection = |section: usize, count: usize| ContentNode::BlockQuote {
            children: (1..=count)
                .map(|index| paragraph(format!("10.{section}.{index}. Subsection")))
                .collect(),
            style: Default::default(),
        };
        let chapter = ContentNode::BlockQuote {
            children: vec![
                paragraph("10.1. Applications from a system viewpoint".to_string()),
                subsection(1, 3),
                paragraph("10.2. Making a release".to_string()),
                subsection(2, 6),
                paragraph("10.3. Release packaging".to_string()),
                subsection(3, 3),
                paragraph("10.4. Installing a release".to_string()),
                paragraph("10.5. Summary".to_string()),
            ],
            style: Default::default(),
        };
        let chapter_text_len = content_node_text_len(&chapter);

        let pages = paginate_epub_chapter(&[chapter], None, 16.0, 1.6, Size::new(785.0, 865.0));

        assert_eq!(pages.len(), 1, "nested TOC entries fit on one page");
        assert_eq!(content_node_text_len(&pages[0][0].node), chapter_text_len);
    }

    #[test]
    fn epub_paginator_keeps_linked_toc_heading_with_its_first_entry() {
        let paragraph = |text: &str, link: Option<&str>| {
            ContentNode::Paragraph(
                vec![shosai_core::epub::render::TextSpan {
                    text: text.to_string(),
                    bold: false,
                    italic: false,
                    monospace: false,
                    preserve_whitespace: false,
                    link: link.map(str::to_string),
                }],
                Default::default(),
            )
        };
        let entries = (1..=4)
            .map(|index| paragraph(&format!("13.{index}. Entry"), Some("chapter-13.xhtml")))
            .collect();
        let nodes = vec![
            ContentNode::Heading {
                level: 1,
                text: "Previous chapter".to_string(),
                style: Default::default(),
            },
            paragraph("Previous summary", None),
            paragraph("Chapter 13", Some("chapter-13.xhtml")),
            ContentNode::BlockQuote {
                children: vec![ContentNode::BlockQuote {
                    children: entries,
                    style: Default::default(),
                }],
                style: Default::default(),
            },
        ];

        let pages = paginate_epub_chapter(&nodes, None, 16.0, 1.6, Size::new(240.0, 180.0));

        let second_page_nodes = pages[1]
            .iter()
            .map(|page_node| page_node.node.clone())
            .collect::<Vec<_>>();
        let second_page_text = shosai_core::search::extract_text_from_nodes(&second_page_nodes);
        assert!(second_page_text.contains("Chapter 13"));
        assert!(second_page_text.contains("13.1. Entry"));
        let all_page_nodes = pages
            .iter()
            .flatten()
            .map(|page_node| page_node.node.clone())
            .collect::<Vec<_>>();
        let all_text = shosai_core::search::extract_text_from_nodes(&all_page_nodes);
        for index in 1..=4 {
            assert_eq!(all_text.matches(&format!("13.{index}. Entry")).count(), 1);
        }
    }

    #[test]
    fn epub_paginator_splits_long_blockquotes_without_losing_children() {
        let children = (0..20)
            .map(|index| {
                ContentNode::Paragraph(
                    vec![shosai_core::epub::render::TextSpan {
                        text: format!("Quoted paragraph {index}"),
                        bold: false,
                        italic: false,
                        monospace: false,
                        preserve_whitespace: false,
                        link: None,
                    }],
                    Default::default(),
                )
            })
            .collect::<Vec<_>>();
        let pages = paginate_epub_chapter(
            &[ContentNode::BlockQuote {
                children: children.clone(),
                style: Default::default(),
            }],
            None,
            16.0,
            1.6,
            Size::new(240.0, 180.0),
        );

        assert!(
            pages.len() > 1,
            "a long blockquote must span multiple pages"
        );
        let paginated_children = pages
            .iter()
            .flatten()
            .flat_map(|page_node| match &page_node.node {
                ContentNode::BlockQuote { children, .. } => children.clone(),
                node => panic!("expected blockquote, got {node:?}"),
            })
            .collect::<Vec<_>>();
        assert_eq!(paginated_children, children);
    }

    #[test]
    fn epub_paginator_preserves_offsets_across_nested_blockquote_splits() {
        fn paragraph(text: String) -> ContentNode {
            ContentNode::Paragraph(
                vec![shosai_core::epub::render::TextSpan {
                    text,
                    bold: false,
                    italic: false,
                    monospace: false,
                    preserve_whitespace: false,
                    link: None,
                }],
                Default::default(),
            )
        }

        fn first_text(node: &ContentNode) -> &str {
            match node {
                ContentNode::Heading { text, .. } => text,
                ContentNode::Paragraph(spans, _) => &spans[0].text,
                ContentNode::BlockQuote { children, .. } => first_text(&children[0]),
                node => panic!("expected text content, got {node:?}"),
            }
        }

        let nested = ContentNode::BlockQuote {
            children: (0..12)
                .map(|index| paragraph(format!("Unique nested entry {index:02}")))
                .collect(),
            style: Default::default(),
        };
        let nodes = vec![
            paragraph("Introductory text before the nested quote".to_string()),
            ContentNode::BlockQuote {
                children: vec![nested],
                style: Default::default(),
            },
        ];
        let chapter_text = shosai_core::search::extract_text_from_nodes(&nodes);

        let pages = paginate_epub_chapter(&nodes, None, 16.0, 1.6, Size::new(240.0, 180.0));

        assert!(pages.len() > 1, "the nested quote must be split");
        for page_node in pages.iter().flatten() {
            let text = first_text(&page_node.node);
            let expected = chapter_text
                .find(text)
                .expect("paginated text must exist in the source chapter");
            assert_eq!(
                page_node.text_offset, expected,
                "the page containing {text:?} must retain its source offset"
            );
        }
    }

    #[test]
    fn epub_paginator_keeps_a_linked_label_with_a_splittable_first_entry() {
        let paragraph = |text: String, link: Option<&str>| {
            ContentNode::Paragraph(
                vec![shosai_core::epub::render::TextSpan {
                    text,
                    bold: false,
                    italic: false,
                    monospace: false,
                    preserve_whitespace: false,
                    link: link.map(str::to_string),
                }],
                Default::default(),
            )
        };
        let label = "Chapter 13";
        let first_entry = "Long first entry ".repeat(30);
        let nodes = vec![
            paragraph("Previous page content ".repeat(8), None),
            paragraph(label.to_string(), Some("chapter-13.xhtml")),
            ContentNode::BlockQuote {
                children: vec![paragraph(
                    first_entry.clone(),
                    Some("chapter-13.xhtml#first"),
                )],
                style: Default::default(),
            },
        ];

        let pages = paginate_epub_chapter(&nodes, None, 16.0, 1.6, Size::new(240.0, 180.0));
        let page_text = pages
            .iter()
            .map(|page| {
                shosai_core::search::extract_text_from_nodes(
                    &page
                        .iter()
                        .map(|page_node| page_node.node.clone())
                        .collect::<Vec<_>>(),
                )
            })
            .find(|text| text.contains(label))
            .expect("the linked label must be paginated");

        assert!(
            page_text.contains("Long first entry"),
            "the linked label must not be left on a page by itself"
        );
    }

    #[test]
    fn epub_paginator_reserves_scaled_width_for_chapter_titles() {
        let nodes = vec![ContentNode::Paragraph(
            vec![shosai_core::epub::render::TextSpan {
                text: "Body text".to_string(),
                bold: false,
                italic: false,
                monospace: false,
                preserve_whitespace: false,
                link: None,
            }],
            Default::default(),
        )];
        let title = "Chapter ".repeat(6);

        let pages = paginate_epub_chapter(&nodes, Some(&title), 16.0, 1.6, Size::new(240.0, 150.0));

        assert_eq!(pages.len(), 2);
        assert!(
            pages[0].is_empty(),
            "the title should occupy the first page"
        );
        assert!(matches!(
            pages[1].as_slice(),
            [PageNode {
                node: ContentNode::Paragraph(_, _),
                ..
            }]
        ));
    }

    #[test]
    fn epub_paginator_wraps_enlarged_paragraphs_at_their_scaled_width() {
        let style = shosai_core::epub::render::NodeStyle {
            font_size_multiplier: Some(2.0),
            ..Default::default()
        };
        let text = "Enlarged paragraph text should wrap more tightly";
        let nodes = vec![ContentNode::Paragraph(
            vec![shosai_core::epub::render::TextSpan {
                text: text.to_string(),
                bold: false,
                italic: false,
                monospace: false,
                preserve_whitespace: false,
                link: None,
            }],
            style,
        )];

        let pages = paginate_epub_chapter(&nodes, None, 16.0, 1.6, Size::new(240.0, 110.0));

        assert!(pages.len() > 1, "enlarged text must use its scaled width");
    }

    #[test]
    fn epub_paginator_places_images_on_their_own_page() {
        let pages = paginate_epub_chapter(
            &[
                ContentNode::Paragraph(
                    vec![shosai_core::epub::render::TextSpan {
                        text: "Text before the image".to_string(),
                        bold: false,
                        italic: false,
                        monospace: false,
                        preserve_whitespace: false,
                        link: None,
                    }],
                    Default::default(),
                ),
                ContentNode::Image {
                    src: "portrait.png".to_string(),
                    alt: "Portrait".to_string(),
                },
            ],
            None,
            16.0,
            1.6,
            Size::new(240.0, 180.0),
        );

        assert_eq!(pages.len(), 2);
        assert!(matches!(
            pages[1].as_slice(),
            [PageNode {
                node: ContentNode::Image { .. },
                ..
            }]
        ));
    }

    #[test]
    fn readable_width_caps_long_lines() {
        let page = page_size(Size::new(2_000.0, 900.0), false, 20.0, 16.0, 1.6);
        let characters = page.width / (16.0 * AVERAGE_CHARACTER_WIDTH);
        assert!((characters - MAX_CHARACTERS_PER_LINE as f32).abs() < 0.01);
    }

    #[test]
    fn visible_pages_follow_horizontal_spreads() {
        assert_eq!(visible_pages(0, 3, true), vec![0, 1]);
        assert_eq!(visible_pages(2, 3, true), vec![2]);
    }
}
