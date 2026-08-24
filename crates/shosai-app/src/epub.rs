//! EPUB-specific pagination models and pure page geometry helpers.

use iced::Size;
use shosai_core::epub::render::{ContentNode, TableRow, TableRowGroup};
use shosai_core::epub::{
    EpubFontBook, EpubTextAlign, EpubTextDirection, EpubTextLayout, EpubTextRequest, EpubTextRun,
};

pub(crate) mod math_layout;
pub(crate) mod math_widget;
pub(crate) mod native_text;

pub(crate) const BLOCKQUOTE_SPACING: f32 = 8.0;
pub(crate) const TEXT_LINE_HEIGHT: f32 = 1.2;
pub(crate) const AVERAGE_CHARACTER_WIDTH: f32 = 0.55;
pub(crate) const MAX_CHARACTERS_PER_LINE: usize = 72;
pub(crate) const PAGE_NUMBER_SIZE: f32 = 11.0;
pub(crate) const MAX_EPUB_PAGES: usize = 10_000;
pub(crate) const MIN_EPUB_TABLE_WIDTH: f32 = 360.0;
pub(crate) const EPUB_TABLE_CELL_PADDING: f32 = 6.0;
pub(crate) const EPUB_TABLE_CELL_SPACING: f32 = 4.0;
pub(crate) const EPUB_TABLE_ROW_SPACING: f32 = 8.0;
pub(crate) const INLINE_MATH_WRAP_SPACING: f32 = 0.25;
pub(crate) const MAX_INLINE_MATH_FLOW_ITEMS: usize = 256;
const MAX_INLINE_MATH_LINE_HEIGHTS: f32 = 3.0;
const MIN_EPUB_TABLE_CELL_WIDTH: f32 = 120.0;
const MAX_EPUB_TABLE_WIDTH: f32 = 4_096.0;
const EPUB_PAGINATION_SHAPE_CHUNK: usize = 4 * 1024;

pub(crate) struct EpubPaginationBudget {
    remaining_page_breaks: usize,
}

impl Default for EpubPaginationBudget {
    fn default() -> Self {
        Self {
            remaining_page_breaks: MAX_EPUB_PAGES - 1,
        }
    }
}

impl EpubPaginationBudget {
    pub(crate) fn for_document(chapters: usize) -> Self {
        Self {
            remaining_page_breaks: MAX_EPUB_PAGES.saturating_sub(chapters),
        }
    }
}

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

#[cfg(test)]
pub(crate) fn paginate_epub_chapter(
    nodes: &[ContentNode],
    title: Option<&str>,
    font_size: f32,
    line_spacing: f32,
    page_size: Size,
) -> Vec<PageNodes> {
    paginate_epub_chapter_with_budget(
        nodes,
        title,
        font_size,
        line_spacing,
        page_size,
        None,
        &mut EpubPaginationBudget::default(),
    )
}

pub(crate) fn paginate_epub_chapter_with_budget(
    nodes: &[ContentNode],
    title: Option<&str>,
    font_size: f32,
    line_spacing: f32,
    page_size: Size,
    fonts: Option<&EpubFontBook>,
    budget: &mut EpubPaginationBudget,
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
            let node_height =
                measured_epub_compact_node_height(fonts, node, font_size, page_size.width)
                    .map(|height| height + font_size * line_spacing)
                    .unwrap_or_else(|| {
                        estimated_epub_node_height(
                            node,
                            chars_per_line,
                            lines_per_page,
                            font_size,
                            line_spacing,
                        )
                    });
            let first_child_height =
                measured_epub_compact_node_height(fonts, first_child, font_size, page_size.width)
                    .unwrap_or_else(|| {
                        estimated_epub_compact_node_height(
                            first_child,
                            chars_per_line,
                            lines_per_page,
                            font_size,
                        )
                    });
            if node_height + first_child_height > remaining && push_epub_page(&mut pages, budget) {
                remaining = page_size.height;
            }
        }
        if page_has_content(&pages, first_page_has_title)
            && matches!(node, ContentNode::Paragraph(..))
            && let Some(ContentNode::Math { content, style, .. }) = nodes.get(node_index + 1)
            && content.expression.is_some()
        {
            let label_height =
                measured_epub_compact_node_height(fonts, node, font_size, page_size.width)
                    .map(|height| height + block_spacing)
                    .unwrap_or_else(|| {
                        estimated_epub_node_height(
                            node,
                            chars_per_line,
                            lines_per_page,
                            font_size,
                            line_spacing,
                        )
                    });
            let math_height = measured_epub_compact_node_height_bounded(
                fonts,
                &nodes[node_index + 1],
                font_size,
                page_size.width,
                page_size.height,
            )
            .map(|height| height + block_spacing)
            .unwrap_or_else(|| {
                estimated_epub_node_height(
                    &nodes[node_index + 1],
                    chars_per_line,
                    lines_per_page,
                    font_size,
                    line_spacing,
                )
            });
            // Default-font paragraph heights are estimated. Keep one scaled math line in reserve so
            // measurement drift cannot clip an atomic native widget at the bottom of the page.
            let fit_reserve =
                font_size * TEXT_LINE_HEIGHT * style.font_size_multiplier.unwrap_or(1.0);
            if label_height + math_height + fit_reserve > remaining
                && push_epub_page(&mut pages, budget)
            {
                remaining = page_size.height;
            }
        }
        let text_len = content_node_text_len(node);
        match node {
            ContentNode::Paragraph(spans, style) => {
                let base_size = font_size * style.font_size_multiplier.unwrap_or(1.0);
                let effective_width = paragraph_width(page_size.width, font_size, style);
                let pagination_spans = pagination_inline_spans(
                    spans,
                    base_size,
                    effective_width,
                    page_size.height,
                    style.direction,
                    style.text_align,
                );
                let spans = pagination_spans.as_slice();
                let measure = |spans: &[shosai_core::epub::render::TextSpan]| {
                    measure_epub_spans(
                        fonts,
                        spans,
                        base_size,
                        effective_width,
                        style.direction,
                        style.text_align,
                    )
                };
                if !spans.iter().any(|span| span.math.is_some())
                    && fonts.is_some_and(|fonts| uses_native_fonts(fonts, spans))
                {
                    let saved_page_count = pages.len();
                    let saved_last_page_nodes = pages.last().map_or(0, Vec::len);
                    let saved_remaining = remaining;
                    let saved_page_breaks = budget.remaining_page_breaks;
                    if paginate_measured_paragraph(
                        spans,
                        style,
                        &measure,
                        text_offset,
                        block_spacing,
                        page_size.height,
                        first_page_has_title,
                        &mut pages,
                        &mut remaining,
                        budget,
                    ) {
                        text_offset += text_len + 1;
                        continue;
                    }
                    pages.truncate(saved_page_count);
                    pages
                        .last_mut()
                        .expect("EPUB pagination always retains one page")
                        .truncate(saved_last_page_nodes);
                    remaining = saved_remaining;
                    budget.remaining_page_breaks = saved_page_breaks;
                }
                let mut cursor = EpubSpanCursor::new(spans);
                let style_scale =
                    style.font_size_multiplier.unwrap_or(1.0) * spans_font_scale(spans);
                let text_line_height = font_size * TEXT_LINE_HEIGHT * style_scale;
                let paragraph_chars_per_line =
                    scaled_characters_per_line(chars_per_line, style_scale);
                while cursor.remaining() > 0 {
                    let mut at_page_limit = false;
                    if remaining < text_line_height + block_spacing
                        && page_has_content(&pages, first_page_has_title)
                    {
                        if push_epub_page(&mut pages, budget) {
                            remaining = page_size.height;
                        } else {
                            at_page_limit = true;
                        }
                    }
                    let mut available_lines = ((remaining - block_spacing).max(text_line_height)
                        / text_line_height)
                        .floor()
                        .max(1.0) as usize;
                    let (take, chunk_height) = loop {
                        let available_chars = if at_page_limit {
                            cursor.remaining()
                        } else {
                            paragraph_chars_per_line * available_lines
                        };
                        let take = cursor.split_length(available_chars);
                        let mut preview = cursor.clone();
                        let chunk = preview.take(take);
                        let chunk_height = take.div_ceil(paragraph_chars_per_line).max(1) as f32
                            * text_line_height
                            + inline_math_height_reserve_for_context(
                                &chunk,
                                base_size,
                                effective_width,
                                page_size.height,
                                style.direction,
                                style.text_align,
                            )
                            + block_spacing;
                        if chunk_height <= remaining || available_lines == 1 || at_page_limit {
                            break (take, chunk_height);
                        }
                        available_lines -= 1;
                    };
                    if chunk_height > remaining
                        && page_has_content(&pages, first_page_has_title)
                        && push_epub_page(&mut pages, budget)
                    {
                        remaining = page_size.height;
                        continue;
                    }
                    let consumed = cursor.consumed();
                    let chunk = cursor.take(take);
                    pages.last_mut().unwrap().push(PageNode {
                        node: ContentNode::Paragraph(chunk, style.clone()),
                        text_offset: text_offset + consumed,
                    });
                    remaining = (remaining - chunk_height).max(0.0);
                }
            }
            ContentNode::CodeBlock { code, language } => {
                let mut consumed = 0;
                let mut consumed_bytes = 0;
                let code_line_height = font_size * TEXT_LINE_HEIGHT * 0.85;
                let code_padding = 24.0;
                while consumed < text_len {
                    let mut at_page_limit = false;
                    if remaining < code_line_height + code_padding + block_spacing
                        && page_has_content(&pages, first_page_has_title)
                    {
                        if push_epub_page(&mut pages, budget) {
                            remaining = page_size.height;
                        } else {
                            at_page_limit = true;
                        }
                    }
                    let available_lines = ((remaining - code_padding - block_spacing)
                        .max(code_line_height)
                        / code_line_height)
                        .floor()
                        .max(1.0) as usize;
                    let remaining_code = &code[consumed_bytes..];
                    let chunk = if at_page_limit {
                        remaining_code.to_string()
                    } else {
                        remaining_code
                            .split_inclusive('\n')
                            .take(available_lines)
                            .collect::<String>()
                    };
                    let chunk_len = chunk.chars().count();
                    consumed_bytes += chunk.len();
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
                page_size.width,
                fonts,
                first_page_has_title,
                &mut pages,
                &mut remaining,
                budget,
            ),
            ContentNode::OrderedList { items, start } => paginate_epub_list(
                items,
                Some(*start),
                text_offset,
                chars_per_line,
                font_size,
                line_spacing,
                page_size.height,
                page_size.width,
                fonts,
                first_page_has_title,
                &mut pages,
                &mut remaining,
                budget,
            ),
            ContentNode::BlockQuote { children, style } => {
                let node_height =
                    measured_epub_compact_node_height(fonts, node, font_size, page_size.width)
                        .map(|height| height + font_size * line_spacing)
                        .unwrap_or_else(|| {
                            estimated_epub_node_height(
                                node,
                                chars_per_line,
                                lines_per_page,
                                font_size,
                                line_spacing,
                            )
                        });
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
                    if node_height > remaining
                        && page_has_content(&pages, first_page_has_title)
                        && push_epub_page(&mut pages, budget)
                    {
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
                                blockquote_width(page_size.width, font_size, style),
                                fonts,
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
                            let _ = push_epub_page(&mut pages, budget);
                        }
                        if budget.remaining_page_breaks == 0 {
                            pages.last_mut().unwrap().push(PageNode {
                                node: ContentNode::BlockQuote {
                                    children: remaining_children,
                                    style: style.clone(),
                                },
                                text_offset: text_offset + prefix_text_len,
                            });
                        } else {
                            let child_pages = paginate_epub_chapter_with_budget(
                                &remaining_children,
                                None,
                                font_size,
                                line_spacing,
                                blockquote_continuation_page_size(page_size, font_size, style),
                                fonts,
                                budget,
                            );
                            for (index, child_page) in child_pages.into_iter().enumerate() {
                                if index > 0 {
                                    let _ = push_epub_page(&mut pages, budget);
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
                        }
                        remaining = 0.0;
                    }
                }
            }
            ContentNode::Image { .. } => {
                if page_has_content(&pages, first_page_has_title) {
                    let _ = push_epub_page(&mut pages, budget);
                }
                pages.last_mut().unwrap().push(PageNode {
                    node: node.clone(),
                    text_offset,
                });
                remaining = 0.0;
            }
            ContentNode::Table { .. } => paginate_epub_table(
                node,
                text_offset,
                chars_per_line,
                lines_per_page,
                font_size,
                line_spacing,
                page_size.height,
                first_page_has_title,
                &mut pages,
                &mut remaining,
                budget,
            ),
            _ => {
                let node_height = measured_epub_compact_node_height_bounded(
                    fonts,
                    node,
                    font_size,
                    page_size.width,
                    page_size.height,
                )
                .map(|height| height + font_size * line_spacing)
                .unwrap_or_else(|| {
                    estimated_epub_node_height(
                        node,
                        chars_per_line,
                        lines_per_page,
                        font_size,
                        line_spacing,
                    )
                });
                if node_height > remaining
                    && page_has_content(&pages, first_page_has_title)
                    && push_epub_page(&mut pages, budget)
                {
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

fn push_epub_page(pages: &mut Vec<PageNodes>, budget: &mut EpubPaginationBudget) -> bool {
    if budget.remaining_page_breaks == 0 {
        return false;
    }
    budget.remaining_page_breaks -= 1;
    pages.push(Vec::new());
    true
}

fn page_has_content(pages: &[PageNodes], first_page_has_title: bool) -> bool {
    pages.last().is_some_and(|page| !page.is_empty()) || (first_page_has_title && pages.len() == 1)
}

#[allow(clippy::too_many_arguments)]
fn paginate_epub_table(
    table: &ContentNode,
    text_offset: usize,
    chars_per_line: usize,
    lines_per_page: usize,
    font_size: f32,
    line_spacing: f32,
    page_height: f32,
    first_page_has_title: bool,
    pages: &mut Vec<PageNodes>,
    remaining: &mut f32,
    budget: &mut EpubPaginationBudget,
) {
    let ContentNode::Table {
        caption,
        caption_style,
        row_groups,
        style,
    } = table
    else {
        unreachable!("table pagination requires a table node");
    };
    let mut fragment_offset = text_offset;
    let mut include_caption = !caption.is_empty();
    let mut pending = None;
    let mut pending_height = 0.0;
    let mut fragment_capacity = *remaining;
    let mut page_budget_exhausted = false;

    for group in row_groups {
        for rows in table_row_bands(&group.rows) {
            let band = ContentNode::Table {
                caption: if include_caption {
                    caption.clone()
                } else {
                    Vec::new()
                },
                caption_style: if include_caption {
                    caption_style.clone()
                } else {
                    None
                },
                row_groups: vec![TableRowGroup {
                    kind: group.kind,
                    rows: rows.to_vec(),
                }],
                style: style.clone(),
            };
            include_caption = false;

            let mut candidate = pending.clone().unwrap_or_else(|| band.clone());
            if pending.is_some() {
                append_table_band(&mut candidate, group.kind, rows);
            }
            let candidate_height = estimated_epub_node_height(
                &candidate,
                chars_per_line,
                lines_per_page,
                font_size,
                line_spacing,
            );

            if pending.is_some() && candidate_height > fragment_capacity && !page_budget_exhausted {
                if budget.remaining_page_breaks == 0 {
                    page_budget_exhausted = true;
                    pending = Some(candidate);
                    pending_height = candidate_height;
                    continue;
                }
                let fragment = pending.take().expect("pending table fragment must exist");
                let fragment_len = content_node_text_len(&fragment);
                pages.last_mut().unwrap().push(PageNode {
                    node: fragment,
                    text_offset: fragment_offset,
                });
                fragment_offset += fragment_len;
                *remaining = (fragment_capacity - pending_height).max(0.0);
                let _ = push_epub_page(pages, budget);
                *remaining = page_height;
                fragment_capacity = *remaining;
                pending_height = estimated_epub_node_height(
                    &band,
                    chars_per_line,
                    lines_per_page,
                    font_size,
                    line_spacing,
                );
                pending = Some(band);
                continue;
            }

            if pending.is_none()
                && candidate_height > *remaining
                && page_has_content(pages, first_page_has_title)
                && push_epub_page(pages, budget)
            {
                *remaining = page_height;
                fragment_capacity = *remaining;
            }
            pending = Some(candidate);
            pending_height = candidate_height;
        }
    }

    if let Some(fragment) = pending {
        pages.last_mut().unwrap().push(PageNode {
            node: fragment,
            text_offset: fragment_offset,
        });
        *remaining = (fragment_capacity - pending_height).max(0.0);
    } else if !caption.is_empty() {
        let height = estimated_epub_node_height(
            table,
            chars_per_line,
            lines_per_page,
            font_size,
            line_spacing,
        );
        if height > *remaining
            && page_has_content(pages, first_page_has_title)
            && push_epub_page(pages, budget)
        {
            *remaining = page_height;
        }
        pages.last_mut().unwrap().push(PageNode {
            node: table.clone(),
            text_offset,
        });
        *remaining = (*remaining - height).max(0.0);
    }
}

fn append_table_band(
    fragment: &mut ContentNode,
    kind: shosai_core::epub::render::TableRowGroupKind,
    rows: &[TableRow],
) {
    let ContentNode::Table { row_groups, .. } = fragment else {
        unreachable!("table bands can only be appended to table fragments");
    };
    if let Some(group) = row_groups.last_mut().filter(|group| group.kind == kind) {
        group.rows.extend_from_slice(rows);
    } else {
        row_groups.push(TableRowGroup {
            kind,
            rows: rows.to_vec(),
        });
    }
}

fn table_row_bands(rows: &[TableRow]) -> Vec<&[TableRow]> {
    let mut bands = Vec::new();
    let mut start = 0;
    while start < rows.len() {
        let mut end = start + 1;
        let mut row_index = start;
        while row_index < end {
            for cell in &rows[row_index].cells {
                let span = if cell.row_span == 0 {
                    rows.len() - row_index
                } else {
                    usize::from(cell.row_span)
                };
                end = end.max((row_index + span).min(rows.len()));
            }
            row_index += 1;
        }
        bands.push(&rows[start..end]);
        start = end;
    }
    bands
}

pub(crate) fn epub_table_layout_width(row_groups: &[TableRowGroup], available_width: f32) -> f32 {
    let columns = row_groups
        .iter()
        .flat_map(|group| &group.rows)
        .map(|row| {
            row.cells
                .iter()
                .map(|cell| usize::from(cell.column_span.max(1)))
                .sum::<usize>()
        })
        .max()
        .unwrap_or(1);
    (columns as f32 * MIN_EPUB_TABLE_CELL_WIDTH)
        .max(MIN_EPUB_TABLE_WIDTH)
        .max(available_width)
        .min(MAX_EPUB_TABLE_WIDTH)
}

pub(crate) fn epub_table_cell_content_width(
    row: &TableRow,
    cell_index: usize,
    table_width: f32,
) -> f32 {
    let portions = row
        .cells
        .iter()
        .map(|cell| f32::from(cell.column_span.max(1)))
        .sum::<f32>()
        .max(1.0);
    let available =
        (table_width - BLOCKQUOTE_SPACING * row.cells.len().saturating_sub(1) as f32).max(1.0);
    let portion = f32::from(row.cells[cell_index].column_span.max(1));
    (available * portion / portions - 2.0 * EPUB_TABLE_CELL_PADDING).max(1.0)
}

fn measure_epub_spans(
    fonts: Option<&EpubFontBook>,
    spans: &[shosai_core::epub::render::TextSpan],
    base_size: f32,
    max_width: f32,
    direction: shosai_core::epub::style::TextDirection,
    alignment: Option<shosai_core::epub::style::TextAlignment>,
) -> Option<EpubTextLayout> {
    measure_epub_spans_with_prefix(
        fonts, "", base_size, spans, base_size, max_width, direction, alignment,
    )
}

#[allow(clippy::too_many_arguments)]
fn measure_epub_spans_with_prefix(
    fonts: Option<&EpubFontBook>,
    prefix: &str,
    prefix_size: f32,
    spans: &[shosai_core::epub::render::TextSpan],
    base_size: f32,
    max_width: f32,
    direction: shosai_core::epub::style::TextDirection,
    alignment: Option<shosai_core::epub::style::TextAlignment>,
) -> Option<EpubTextLayout> {
    if spans_text_len(spans).saturating_add(prefix.chars().count()) > EPUB_PAGINATION_SHAPE_CHUNK {
        return None;
    }
    let fonts = fonts.filter(|fonts| uses_native_fonts(fonts, spans))?;
    let mut runs = Vec::with_capacity(spans.len() + usize::from(!prefix.is_empty()));
    if !prefix.is_empty() {
        runs.push(EpubTextRun {
            text: prefix.to_owned(),
            family: None,
            monospace: false,
            font_size: prefix_size,
            bold: false,
            italic: false,
            foreground: [0, 0, 0, 255],
            link: None,
        });
    }
    runs.extend(spans.iter().map(|span| EpubTextRun {
        text: span.text.clone(),
        family: span.font_family.as_deref().map(str::to_owned),
        monospace: span.monospace,
        font_size: base_size * span.font_size_multiplier,
        bold: span.bold,
        italic: span.italic,
        foreground: [0, 0, 0, 255],
        link: None,
    }));
    let line_height = runs
        .iter()
        .map(|run| run.font_size)
        .fold(base_size, f32::max)
        * TEXT_LINE_HEIGHT;
    fonts
        .measure_text(&EpubTextRequest {
            runs,
            max_width: max_width.max(1.0),
            line_height,
            scale: 1.0,
            align: match alignment {
                Some(shosai_core::epub::style::TextAlignment::Center) => EpubTextAlign::Center,
                Some(shosai_core::epub::style::TextAlignment::Right) => EpubTextAlign::Right,
                Some(shosai_core::epub::style::TextAlignment::Justify) => EpubTextAlign::Justified,
                _ => EpubTextAlign::Left,
            },
            direction: match direction {
                shosai_core::epub::style::TextDirection::Ltr => EpubTextDirection::LeftToRight,
                shosai_core::epub::style::TextDirection::Rtl => EpubTextDirection::RightToLeft,
            },
            highlights: Vec::new(),
        })
        .ok()
}

pub(crate) fn paragraph_width(
    width: f32,
    font_size: f32,
    style: &shosai_core::epub::render::NodeStyle,
) -> f32 {
    (width - style.margin_left_em.unwrap_or(0.0) * font_size).max(1.0)
}

fn blockquote_width(
    width: f32,
    font_size: f32,
    style: &shosai_core::epub::render::NodeStyle,
) -> f32 {
    (width - style.margin_left_em.unwrap_or(1.0) * font_size).max(1.0)
}

fn blockquote_continuation_page_size(
    page_size: Size,
    font_size: f32,
    style: &shosai_core::epub::render::NodeStyle,
) -> Size {
    Size::new(
        blockquote_width(page_size.width, font_size, style),
        page_size.height,
    )
}

pub(crate) fn uses_native_fonts(
    fonts: &EpubFontBook,
    spans: &[shosai_core::epub::render::TextSpan],
) -> bool {
    spans_text_len(spans) <= shosai_core::epub::EPUB_TEXT_MAX_SCALARS
        && spans.iter().any(|span| {
            span.font_family
                .as_deref()
                .is_some_and(|family| fonts.contains_family(family))
        })
}

#[allow(clippy::too_many_arguments)]
fn paginate_measured_paragraph(
    spans: &[shosai_core::epub::render::TextSpan],
    style: &shosai_core::epub::render::NodeStyle,
    measure: &impl Fn(&[shosai_core::epub::render::TextSpan]) -> Option<EpubTextLayout>,
    text_offset: usize,
    block_spacing: f32,
    page_height: f32,
    first_page_has_title: bool,
    pages: &mut Vec<PageNodes>,
    remaining: &mut f32,
    budget: &mut EpubPaginationBudget,
) -> bool {
    let text_len = spans_text_len(spans);
    let mut start = 0;
    let mut shape_window = EPUB_PAGINATION_SHAPE_CHUNK;
    let mut shaping_work = text_len
        .saturating_mul(4)
        .saturating_add(EPUB_PAGINATION_SHAPE_CHUNK);
    while start < text_len {
        let window_len = (text_len - start).min(shape_window);
        if shaping_work < window_len {
            return false;
        }
        shaping_work -= window_len;
        let remaining_spans = slice_epub_spans(spans, start, window_len);
        let Some(layout) = measure(&remaining_spans) else {
            return false;
        };
        let line_height = layout
            .lines
            .windows(2)
            .map(|lines| lines[1].top - lines[0].top)
            .find(|height| *height > 0.0)
            .unwrap_or_else(|| layout.height.max(1.0));
        if *remaining < line_height + block_spacing
            && page_has_content(pages, first_page_has_title)
            && push_epub_page(pages, budget)
        {
            *remaining = page_height;
        }
        let at_limit = budget.remaining_page_breaks == 0;
        let available = (*remaining - block_spacing).max(line_height);
        let fit = (available / line_height).floor().max(1.0) as usize;
        let end_line = if at_limit {
            layout.lines.len()
        } else {
            fit.min(layout.lines.len())
        };
        let mut length = layout
            .lines
            .get(end_line.saturating_sub(1))
            .map_or(window_len, |line| line.scalars.end)
            .min(window_len)
            .max(1);
        let mut page_spans = slice_epub_spans(spans, start, length);
        if shaping_work < length {
            return false;
        }
        shaping_work -= length;
        let Some(mut page_layout) = measure(&page_spans) else {
            return false;
        };
        while !at_limit && page_layout.height > available && length > 1 {
            let previous = page_layout
                .lines
                .iter()
                .rev()
                .nth(1)
                .map_or(0, |line| line.scalars.end);
            if previous == 0 || previous >= length {
                break;
            }
            if shaping_work < previous {
                return false;
            }
            shaping_work -= previous;
            let adjusted_spans = slice_epub_spans(spans, start, previous);
            let Some(adjusted) = measure(&adjusted_spans) else {
                return false;
            };
            length = previous;
            page_spans = adjusted_spans;
            page_layout = adjusted;
        }
        pages.last_mut().unwrap().push(PageNode {
            node: ContentNode::Paragraph(page_spans, style.clone()),
            text_offset: text_offset + start,
        });
        *remaining = (*remaining - (page_layout.height + block_spacing)).max(0.0);
        start += length;
        shape_window = length
            .saturating_mul(2)
            .clamp(1, EPUB_PAGINATION_SHAPE_CHUNK);
    }
    true
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
    page_width: f32,
    fonts: Option<&EpubFontBook>,
    first_page_has_title: bool,
    pages: &mut Vec<PageNodes>,
    remaining: &mut f32,
    budget: &mut EpubPaginationBudget,
) {
    let pagination_items = items
        .iter()
        .map(|item| {
            pagination_inline_spans(
                item,
                font_size,
                page_width,
                page_height,
                shosai_core::epub::style::TextDirection::Ltr,
                None,
            )
        })
        .collect::<Vec<_>>();
    let items = pagination_items.as_slice();
    let mut consumed_items = 0;
    let mut consumed_text = 0;
    let block_spacing = font_size * line_spacing;

    while consumed_items < items.len() {
        let first_scale = spans_font_scale(&items[consumed_items]);
        let first_line_height = font_size * TEXT_LINE_HEIGHT * first_scale;
        if *remaining < first_line_height + block_spacing
            && page_has_content(pages, first_page_has_title)
        {
            if push_epub_page(pages, budget) {
                *remaining = page_height;
            } else {
                pages.last_mut().unwrap().push(PageNode {
                    node: epub_list_node(
                        &items[consumed_items..],
                        ordered_start.map(|start| start + consumed_items),
                    ),
                    text_offset: text_offset + consumed_text,
                });
                return;
            }
        }

        let available_height = (*remaining - block_spacing).max(first_line_height);
        let mut chunk_height = 0.0;
        let mut take = 0;
        for (chunk_index, item) in items[consumed_items..].iter().enumerate() {
            let scale = spans_font_scale(item);
            let item_chars_per_line = scaled_characters_per_line(chars_per_line, scale);
            let item_lines = (spans_text_len(item) + 4)
                .div_ceil(item_chars_per_line)
                .max(1);
            let item_spacing = if take == 0 { 0.0 } else { 4.0 };
            let absolute_index = consumed_items + chunk_index;
            let prefix = ordered_start.map_or_else(
                || "  \u{2022} ".to_owned(),
                |start| format!("  {}. ", start + absolute_index),
            );
            let item_height =
                measure_epub_spans_with_prefix(
                    fonts,
                    &prefix,
                    font_size * scale,
                    item,
                    font_size,
                    page_width,
                    shosai_core::epub::style::TextDirection::Ltr,
                    None,
                )
                .map_or(
                    item_lines as f32 * font_size * TEXT_LINE_HEIGHT * scale,
                    |layout| layout.height,
                ) + inline_math_height_reserve(item, font_size, page_width, page_height);
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
            if push_epub_page(pages, budget) {
                *remaining = page_height;
            } else {
                pages.last_mut().unwrap().push(PageNode {
                    node: epub_list_node(
                        &items[consumed_items..],
                        ordered_start.map(|start| start + consumed_items),
                    ),
                    text_offset: text_offset + consumed_text,
                });
                return;
            }
            continue;
        }

        let node = epub_list_node(
            &items[consumed_items..consumed_items + take],
            ordered_start.map(|start| start + consumed_items),
        );
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

fn epub_list_node(
    items: &[Vec<shosai_core::epub::render::TextSpan>],
    ordered_start: Option<usize>,
) -> ContentNode {
    match ordered_start {
        Some(start) => ContentNode::OrderedList {
            items: items.to_vec(),
            start,
        },
        None => ContentNode::UnorderedList(items.to_vec()),
    }
}

#[derive(Clone)]
struct EpubSpanCursor<'a> {
    spans: &'a [shosai_core::epub::render::TextSpan],
    span_index: usize,
    byte_offset: usize,
    consumed: usize,
    remaining: usize,
}

impl<'a> EpubSpanCursor<'a> {
    fn new(spans: &'a [shosai_core::epub::render::TextSpan]) -> Self {
        Self {
            spans,
            span_index: 0,
            byte_offset: 0,
            consumed: 0,
            remaining: spans_text_len(spans),
        }
    }

    fn consumed(&self) -> usize {
        self.consumed
    }

    fn remaining(&self) -> usize {
        self.remaining
    }

    fn split_length(&self, maximum: usize) -> usize {
        if self.remaining <= maximum {
            return self.remaining;
        }
        let mut length = 0;
        let mut last_whitespace = None;
        for (index, span) in self.spans[self.span_index..].iter().enumerate() {
            let start = if index == 0 { self.byte_offset } else { 0 };
            if span.math.is_some() {
                let span_len = span.text[start..].chars().count();
                if length + span_len > maximum {
                    return if length == 0 { span_len } else { length };
                }
                length += span_len;
                continue;
            }
            for character in span.text[start..].chars() {
                if length == maximum {
                    break;
                }
                length += 1;
                if character.is_whitespace() {
                    last_whitespace = Some(length);
                }
            }
            if length == maximum {
                break;
            }
        }
        last_whitespace
            .filter(|length| *length >= maximum / 2)
            .unwrap_or(maximum)
    }

    fn take(&mut self, length: usize) -> Vec<shosai_core::epub::render::TextSpan> {
        let mut output = Vec::new();
        let mut remaining = length;
        while remaining > 0 && self.span_index < self.spans.len() {
            let source = &self.spans[self.span_index];
            let suffix = &source.text[self.byte_offset..];
            let mut bytes = 0;
            let mut characters = 0;
            for character in suffix.chars().take(remaining) {
                bytes += character.len_utf8();
                characters += 1;
            }
            if characters > 0 {
                let mut span = source.clone();
                span.text = suffix[..bytes].to_string();
                output.push(span);
                self.byte_offset += bytes;
                self.consumed += characters;
                self.remaining -= characters;
                remaining -= characters;
            }
            if self.byte_offset == source.text.len() {
                self.span_index += 1;
                self.byte_offset = 0;
            }
        }
        output
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
                if local_start != 0 || local_end != span_len {
                    sliced.math = None;
                }
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
    page_width: f32,
    fonts: Option<&EpubFontBook>,
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
        let child_height = measured_epub_compact_node_height(fonts, child, font_size, page_width)
            .unwrap_or_else(|| {
                estimated_epub_compact_node_height(child, chars_per_line, lines_per_page, font_size)
            });
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
                        blockquote_width(page_width, font_size, style),
                        fonts,
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
            let effective_width = paragraph_width(page_width, font_size, style);
            let pagination_spans = pagination_inline_spans(
                spans,
                font_size * style_scale,
                effective_width,
                paragraph_available.max(1.0),
                style.direction,
                style.text_align,
            );
            let spans = pagination_spans.as_slice();
            let available_lines = (paragraph_available / line_height).floor().max(0.0) as usize;
            let maximum = paragraph_chars_per_line * available_lines;
            let text_len = spans_text_len(spans);
            let measured = measure_epub_spans(
                fonts,
                spans,
                font_size * style_scale,
                effective_width,
                style.direction,
                style.text_align,
            );
            let mut take = measured.as_ref().map_or_else(
                || epub_span_split_length(spans, 0, maximum),
                |layout| {
                    layout
                        .lines
                        .iter()
                        .take_while(|line| line.top + line_height <= paragraph_available)
                        .last()
                        .map_or(0, |line| line.scalars.end)
                },
            );
            let mut reshaped = None;
            while measured.is_some() && take > 0 && take < text_len {
                let candidate = slice_epub_spans(spans, 0, take);
                let Some(layout) = measure_epub_spans(
                    fonts,
                    &candidate,
                    font_size * style_scale,
                    effective_width,
                    style.direction,
                    style.text_align,
                ) else {
                    take = 0;
                    break;
                };
                if layout.height <= paragraph_available {
                    reshaped = Some(layout);
                    break;
                }
                let previous = layout
                    .lines
                    .iter()
                    .rev()
                    .nth(1)
                    .map_or(0, |line| line.scalars.end);
                if previous == 0 || previous >= take {
                    take = 0;
                    break;
                }
                take = previous;
            }
            if take > 0 && take < text_len {
                let prefix_spans = slice_epub_spans(spans, 0, take);
                let remaining_spans = slice_epub_spans(spans, take, text_len - take);
                let paragraph_height = reshaped.or(measured).map_or_else(
                    || take.div_ceil(paragraph_chars_per_line).max(1) as f32 * line_height,
                    |layout| layout.height,
                ) + inline_math_height_reserve_for_context(
                    &prefix_spans,
                    font_size * style_scale,
                    effective_width,
                    paragraph_available.max(1.0),
                    style.direction,
                    style.text_align,
                );
                prefix.push(ContentNode::Paragraph(prefix_spans, style.clone()));
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
            spans,
            level,
            style,
            ..
        } => {
            let heading_scale = match level {
                1 => 2.0,
                2 => 1.6,
                3 => 1.3,
                4 => 1.1,
                _ => 1.0,
            };
            let style_scale = style.font_size_multiplier.unwrap_or(1.0);
            let scale = heading_scale * style_scale * spans_font_scale(spans);
            wrapped(spans_text_len(spans), scale) * text_line_height * scale
                + inline_math_height_reserve(
                    spans,
                    font_size * heading_scale * style_scale,
                    chars_per_line as f32 * font_size * AVERAGE_CHARACTER_WIDTH,
                    f32::MAX,
                )
        }
        ContentNode::BlockQuote { children, .. } => {
            estimated_epub_blockquote_height(children, chars_per_line, lines_per_page, font_size)
        }
        ContentNode::Table {
            caption,
            caption_style,
            row_groups,
            style,
        } => {
            let outer_width = chars_per_line as f32 * font_size * AVERAGE_CHARACTER_WIDTH;
            let table_width = epub_table_layout_width(row_groups, outer_width);
            let table_content_width =
                (table_width - style.margin_left_em.unwrap_or(0.0) * font_size).max(1.0);
            let caption_height = (!caption.is_empty()).then(|| {
                let scale = caption_style
                    .as_ref()
                    .and_then(|style| style.font_size_multiplier)
                    .unwrap_or(1.0)
                    * spans_font_scale(caption);
                wrapped(spans_text_len(caption), scale) * text_line_height * scale
                    + inline_math_height_reserve(
                        caption,
                        font_size
                            * caption_style
                                .as_ref()
                                .and_then(|style| style.font_size_multiplier)
                                .unwrap_or(1.0),
                        table_content_width,
                        f32::MAX,
                    )
            });
            let row_heights = row_groups
                .iter()
                .flat_map(|group| &group.rows)
                .map(|row| {
                    row.cells
                        .iter()
                        .enumerate()
                        .map(|(cell_index, cell)| {
                            let cell_width =
                                epub_table_cell_content_width(row, cell_index, table_content_width);
                            let cell_chars_per_line =
                                (cell_width / (font_size * AVERAGE_CHARACTER_WIDTH).max(1.0))
                                    .floor()
                                    .max(1.0) as usize;
                            cell.children
                                .iter()
                                .map(|child| {
                                    estimated_epub_compact_node_height(
                                        child,
                                        cell_chars_per_line,
                                        lines_per_page,
                                        font_size,
                                    )
                                })
                                .sum::<f32>()
                                + EPUB_TABLE_CELL_SPACING
                                    * cell.children.len().saturating_sub(1) as f32
                                + 2.0 * EPUB_TABLE_CELL_PADDING
                        })
                        .fold(2.0 * EPUB_TABLE_CELL_PADDING, f32::max)
                })
                .collect::<Vec<_>>();
            let table_children = row_heights.len() + usize::from(caption_height.is_some());
            caption_height.unwrap_or(0.0)
                + row_heights.into_iter().sum::<f32>()
                + EPUB_TABLE_ROW_SPACING * table_children.saturating_sub(1) as f32
        }
        ContentNode::Math { content, style, .. } => {
            let scale = style.font_size_multiplier.unwrap_or(1.0);
            wrapped(content.fallback.chars().count(), scale) * text_line_height * scale
        }
        ContentNode::UnorderedList(items) | ContentNode::OrderedList { items, .. } => {
            items
                .iter()
                .map(|item| {
                    let scale = spans_font_scale(item);
                    wrapped(spans_text_len(item) + 4, scale) * text_line_height * scale
                        + inline_math_height_reserve(
                            item,
                            font_size,
                            chars_per_line as f32 * font_size * AVERAGE_CHARACTER_WIDTH,
                            f32::MAX,
                        )
                })
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
            let scale = style.font_size_multiplier.unwrap_or(1.0) * spans_font_scale(spans);
            wrapped(spans_text_len(spans), scale) * text_line_height * scale
                + inline_math_height_reserve(
                    spans,
                    font_size * style.font_size_multiplier.unwrap_or(1.0),
                    chars_per_line as f32 * font_size * AVERAGE_CHARACTER_WIDTH,
                    f32::MAX,
                )
        }
    }
}

fn measured_epub_compact_node_height(
    fonts: Option<&EpubFontBook>,
    node: &ContentNode,
    font_size: f32,
    width: f32,
) -> Option<f32> {
    measured_epub_compact_node_height_bounded(fonts, node, font_size, width, f32::MAX)
}

fn measured_epub_compact_node_height_bounded(
    fonts: Option<&EpubFontBook>,
    node: &ContentNode,
    font_size: f32,
    width: f32,
    height: f32,
) -> Option<f32> {
    match node {
        ContentNode::Heading {
            spans,
            level,
            style,
        } => {
            let heading_scale = match level {
                1 => 2.0,
                2 => 1.6,
                3 => 1.3,
                4 => 1.1,
                _ => 1.0,
            } * style.font_size_multiplier.unwrap_or(1.0);
            measure_epub_spans(
                fonts,
                spans,
                font_size * heading_scale,
                width,
                style.direction,
                style.text_align,
            )
            .map(|layout| {
                layout.height
                    + inline_math_height_reserve_for_context(
                        spans,
                        font_size * heading_scale,
                        width,
                        height,
                        style.direction,
                        style.text_align,
                    )
            })
        }
        ContentNode::Paragraph(spans, style) => {
            let base_size = font_size * style.font_size_multiplier.unwrap_or(1.0);
            measure_epub_spans(
                fonts,
                spans,
                base_size,
                paragraph_width(width, font_size, style),
                style.direction,
                style.text_align,
            )
            .map(|layout| {
                let effective_width = paragraph_width(width, font_size, style);
                layout.height
                    + inline_math_height_reserve_for_context(
                        spans,
                        base_size,
                        effective_width,
                        height,
                        style.direction,
                        style.text_align,
                    )
            })
        }
        ContentNode::Math { content, style, .. } => {
            let span = shosai_core::epub::render::TextSpan {
                text: content.fallback.clone(),
                math: None,
                font_family: None,
                bold: false,
                italic: false,
                monospace: false,
                font_size_multiplier: 1.0,
                preserve_whitespace: false,
                link: None,
            };
            let size = font_size * style.font_size_multiplier.unwrap_or(1.0);
            if let Some(layout) = content.expression.as_ref().and_then(|expression| {
                math_layout::layout_math_for_bounds(expression, size, width, height)
            }) {
                return Some(layout.height);
            }
            measure_epub_spans(
                fonts,
                std::slice::from_ref(&span),
                size,
                width,
                style.direction,
                style.text_align,
            )
            .map(|layout| layout.height)
        }
        ContentNode::UnorderedList(items) => {
            measured_epub_list_height(fonts, items, None, font_size, width)
        }
        ContentNode::OrderedList { items, start } => {
            measured_epub_list_height(fonts, items, Some(*start), font_size, width)
        }
        ContentNode::BlockQuote { children, style } => {
            let width = blockquote_width(width, font_size, style);
            let heights: Option<Vec<_>> = children
                .iter()
                .map(|child| measured_epub_compact_node_height(fonts, child, font_size, width))
                .collect();
            heights.map(|heights| {
                heights.into_iter().sum::<f32>()
                    + BLOCKQUOTE_SPACING * children.len().saturating_sub(1) as f32
            })
        }
        _ => None,
    }
}

fn measured_epub_list_height(
    fonts: Option<&EpubFontBook>,
    items: &[Vec<shosai_core::epub::render::TextSpan>],
    ordered_start: Option<usize>,
    font_size: f32,
    width: f32,
) -> Option<f32> {
    let mut any = false;
    let height = items
        .iter()
        .enumerate()
        .map(|(index, item)| {
            let scale = spans_font_scale(item);
            let fallback = (spans_text_len(item) + 4)
                .div_ceil(scaled_characters_per_line(
                    (width / (font_size * AVERAGE_CHARACTER_WIDTH).max(1.0)) as usize,
                    scale,
                ))
                .max(1) as f32
                * font_size
                * TEXT_LINE_HEIGHT
                * scale;
            let prefix = ordered_start.map_or_else(
                || "  \u{2022} ".to_owned(),
                |start| format!("  {}. ", start + index),
            );
            measure_epub_spans_with_prefix(
                fonts,
                &prefix,
                font_size * scale,
                item,
                font_size,
                width,
                shosai_core::epub::style::TextDirection::Ltr,
                None,
            )
            .map_or(fallback, |layout| {
                any = true;
                layout.height
            }) + inline_math_height_reserve(item, font_size, width, f32::MAX)
        })
        .sum::<f32>()
        + 4.0 * items.len().saturating_sub(1) as f32;
    any.then_some(height)
}

pub(crate) fn spans_text_len(spans: &[shosai_core::epub::render::TextSpan]) -> usize {
    spans.iter().map(|span| span.text.chars().count()).sum()
}

pub(crate) fn spans_font_scale(spans: &[shosai_core::epub::render::TextSpan]) -> f32 {
    spans
        .iter()
        .map(|span| span.font_size_multiplier)
        .reduce(f32::max)
        .unwrap_or(1.0)
}

fn inline_math_height_reserve(
    spans: &[shosai_core::epub::render::TextSpan],
    base_size: f32,
    width: f32,
    height: f32,
) -> f32 {
    inline_math_height_reserve_for_context(
        spans,
        base_size,
        width,
        height,
        shosai_core::epub::style::TextDirection::Ltr,
        None,
    )
}

fn inline_math_height_reserve_for_context(
    spans: &[shosai_core::epub::render::TextSpan],
    base_size: f32,
    width: f32,
    height: f32,
    direction: shosai_core::epub::style::TextDirection,
    alignment: Option<shosai_core::epub::style::TextAlignment>,
) -> f32 {
    let geometry = spans
        .iter()
        .filter_map(|span| {
            let layout = layout_inline_math_span_for_context(
                span, base_size, width, height, direction, alignment,
            )?;
            let line_height = base_size * span.font_size_multiplier * TEXT_LINE_HEIGHT;
            Some((layout.height - line_height).max(0.0))
        })
        .sum::<f32>();
    if geometry == 0.0 {
        return 0.0;
    }
    let scale = spans_font_scale(spans);
    let chars_per_line = (width / (base_size * AVERAGE_CHARACTER_WIDTH).max(1.0))
        .floor()
        .max(1.0) as usize;
    let lines = spans_text_len(spans)
        .div_ceil(scaled_characters_per_line(chars_per_line, scale))
        .max(1);
    geometry + lines.saturating_sub(1) as f32 * base_size * INLINE_MATH_WRAP_SPACING
}

pub(crate) fn layout_inline_math_span(
    span: &shosai_core::epub::render::TextSpan,
    base_size: f32,
    width: f32,
    height: f32,
) -> Option<math_layout::MathLayout> {
    let math = span.math.as_ref()?;
    if math.display != shosai_core::epub::MathDisplay::Inline {
        return None;
    }
    let expression = math.expression.as_ref()?;
    let size = base_size * span.font_size_multiplier;
    math_layout::layout_math_for_bounds(
        expression,
        size,
        width,
        height.min(size * TEXT_LINE_HEIGHT * MAX_INLINE_MATH_LINE_HEIGHTS),
    )
}

pub(crate) fn layout_inline_math_span_for_context(
    span: &shosai_core::epub::render::TextSpan,
    base_size: f32,
    width: f32,
    height: f32,
    direction: shosai_core::epub::style::TextDirection,
    alignment: Option<shosai_core::epub::style::TextAlignment>,
) -> Option<math_layout::MathLayout> {
    if direction != shosai_core::epub::style::TextDirection::Ltr
        || alignment == Some(shosai_core::epub::style::TextAlignment::Justify)
    {
        return None;
    }
    layout_inline_math_span(span, base_size, width, height)
}

fn pagination_inline_spans(
    spans: &[shosai_core::epub::render::TextSpan],
    base_size: f32,
    width: f32,
    height: f32,
    direction: shosai_core::epub::style::TextDirection,
    alignment: Option<shosai_core::epub::style::TextAlignment>,
) -> Vec<shosai_core::epub::render::TextSpan> {
    let admit_flow = inline_math_flow_is_admitted(spans);
    spans
        .iter()
        .cloned()
        .map(|mut span| {
            if !admit_flow
                || layout_inline_math_span_for_context(
                    &span, base_size, width, height, direction, alignment,
                )
                .is_none()
            {
                span.math = None;
            }
            span
        })
        .collect()
}

pub(crate) fn inline_math_flow_is_admitted(spans: &[shosai_core::epub::render::TextSpan]) -> bool {
    spans
        .iter()
        .map(|span| span.text.split_inclusive(char::is_whitespace).count())
        .sum::<usize>()
        <= MAX_INLINE_MATH_FLOW_ITEMS
}

pub(crate) fn content_node_text_len(node: &ContentNode) -> usize {
    match node {
        ContentNode::Heading { spans, .. } => spans_text_len(spans),
        ContentNode::Paragraph(spans, _) => spans_text_len(spans),
        ContentNode::BlockQuote { children, .. } => children
            .iter()
            .map(|child| content_node_text_len(child) + 1)
            .sum(),
        ContentNode::Table {
            caption,
            row_groups,
            ..
        } => {
            let caption_len = spans_text_len(caption) + usize::from(!caption.is_empty());
            caption_len
                + row_groups
                    .iter()
                    .flat_map(|group| &group.rows)
                    .map(|row| {
                        row.cells
                            .iter()
                            .map(|cell| {
                                cell.children
                                    .iter()
                                    .enumerate()
                                    .map(|(index, child)| {
                                        content_node_text_len(child)
                                            + usize::from(cell.block_starts.contains(&index))
                                    })
                                    .sum::<usize>()
                            })
                            .sum::<usize>()
                            + row.cells.len().saturating_sub(1)
                            + 1
                    })
                    .sum::<usize>()
        }
        ContentNode::UnorderedList(items) | ContentNode::OrderedList { items, .. } => {
            items.iter().map(|spans| spans_text_len(spans) + 1).sum()
        }
        ContentNode::CodeBlock { code, .. } | ContentNode::InlineCode(code) => code.chars().count(),
        ContentNode::Image { alt, .. } => alt.chars().count(),
        ContentNode::Math { content, .. } => content.fallback.chars().count(),
        ContentNode::HorizontalRule => 0,
    }
}

#[cfg(test)]
mod text_layout;

#[cfg(test)]
pub(crate) mod text_shaping;

#[cfg(test)]
mod table_layout;

#[cfg(test)]
mod tests {
    use super::*;

    fn one_line_table(rows: usize) -> ContentNode {
        use shosai_core::epub::render::{
            NodeStyle, TableCell, TableRow, TableRowGroup, TableRowGroupKind, TextSpan,
        };

        let paragraph = || {
            ContentNode::Paragraph(
                vec![TextSpan {
                    text: "cell".into(),
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
            )
        };
        ContentNode::Table {
            caption: Vec::new(),
            caption_style: None,
            row_groups: vec![TableRowGroup {
                kind: TableRowGroupKind::Body,
                rows: (0..rows)
                    .map(|_| TableRow {
                        cells: vec![TableCell {
                            id: None,
                            header: false,
                            scope: None,
                            headers: Vec::new(),
                            row_span: 1,
                            column_span: 1,
                            children: vec![paragraph()],
                            block_starts: Vec::new(),
                            style: NodeStyle::default(),
                        }],
                    })
                    .collect(),
            }],
            style: NodeStyle::default(),
        }
    }

    #[test]
    fn nested_blockquote_and_paragraph_margins_reduce_shaping_width() {
        let block = shosai_core::epub::render::NodeStyle {
            margin_left_em: Some(2.0),
            ..Default::default()
        };
        let paragraph = shosai_core::epub::render::NodeStyle {
            margin_left_em: Some(1.0),
            ..Default::default()
        };
        let inner = blockquote_width(240.0, 16.0, &block);
        assert_eq!(inner, 208.0);
        assert_eq!(blockquote_width(inner, 16.0, &Default::default()), 192.0);
        assert_eq!(paragraph_width(192.0, 16.0, &paragraph), 176.0);
        assert_eq!(
            blockquote_continuation_page_size(Size::new(240.0, 320.0), 16.0, &block),
            Size::new(208.0, 320.0),
            "continued quote pages must retain their effective inner width"
        );
    }

    #[test]
    fn declared_system_families_do_not_select_the_embedded_font_renderer() {
        let epub = shosai_core::epub::EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        assert!(epub.fonts().is_empty());
        let spans = vec![shosai_core::epub::render::TextSpan {
            text: "This must remain visible".into(),
            math: None,
            font_family: Some("serif".into()),
            bold: false,
            italic: false,
            monospace: false,
            font_size_multiplier: 1.0,
            preserve_whitespace: false,
            link: None,
        }];

        assert!(!uses_native_fonts(epub.fonts(), &spans));
    }

    #[test]
    fn semantic_table_lengths_match_shared_search_offsets() {
        let epub = shosai_core::epub::EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/epub-conformance/table.epub").to_vec(),
        )
        .expect("table fixture should be a valid EPUB");
        let chapter = epub.presentation().chapter(0).unwrap();
        let retained = chapter
            .nodes()
            .iter()
            .map(content_node_text_len)
            .sum::<usize>()
            + chapter.nodes().len();

        assert_eq!(retained, chapter.search_text().chars().count());
        assert_eq!(
            chapter
                .nodes()
                .iter()
                .filter(|node| matches!(node, ContentNode::Table { .. }))
                .count(),
            2
        );
    }

    #[test]
    fn table_math_admission_uses_the_padded_cell_width() {
        use shosai_core::epub::render::{
            NodeStyle, TableCell, TableRow, TableRowGroupKind, TextSpan,
        };
        use shosai_core::epub::{MathContent, MathDisplay, MathExpression};

        let token = "abcdefghijklmnopqrstuvwxyzabcdefghij";
        let fallback = format!("({token})/({token})");
        let math = TextSpan {
            text: fallback.clone(),
            math: Some(MathContent {
                display: MathDisplay::Inline,
                expression: Some(MathExpression::Fraction(
                    Box::new(MathExpression::Token(token.into())),
                    Box::new(MathExpression::Token(token.into())),
                )),
                fallback,
            }),
            font_family: None,
            bold: false,
            italic: false,
            monospace: false,
            font_size_multiplier: 1.0,
            preserve_whitespace: false,
            link: None,
        };
        let paragraph = |span: TextSpan| ContentNode::Paragraph(vec![span], NodeStyle::default());
        let cell = |child| TableCell {
            id: None,
            header: false,
            scope: None,
            headers: Vec::new(),
            row_span: 1,
            column_span: 1,
            children: vec![child],
            block_starts: Vec::new(),
            style: NodeStyle::default(),
        };
        let second = TextSpan {
            text: "second cell".into(),
            math: None,
            ..math.clone()
        };
        let table = |first| ContentNode::Table {
            caption: Vec::new(),
            caption_style: None,
            row_groups: vec![TableRowGroup {
                kind: TableRowGroupKind::Body,
                rows: vec![TableRow {
                    cells: vec![cell(first), cell(paragraph(second.clone()))],
                }],
            }],
            style: NodeStyle::default(),
        };
        let outer_width = 400.0;
        let inner_width = (outer_width - BLOCKQUOTE_SPACING) / 2.0 - 2.0 * EPUB_TABLE_CELL_PADDING;
        assert!(layout_inline_math_span(&math, 16.0, outer_width, 300.0).is_some());
        assert!(layout_inline_math_span(&math, 16.0, inner_width, 300.0).is_none());
        let native = table(paragraph(math.clone()));
        let mut fallback_span = math;
        fallback_span.math = None;
        let fallback = table(paragraph(fallback_span));
        let chars_per_line = (outer_width / (16.0 * AVERAGE_CHARACTER_WIDTH)) as usize;

        assert_eq!(
            estimated_epub_compact_node_height(&native, chars_per_line, 20, 16.0),
            estimated_epub_compact_node_height(&fallback, chars_per_line, 20, 16.0),
            "math that does not fit the padded cell must use the same fallback measurement as painting"
        );
    }

    #[test]
    fn table_display_math_height_uses_native_geometry() {
        use shosai_core::epub::render::{
            NodeStyle, TableCell, TableRow, TableRowGroup, TableRowGroupKind,
        };
        use shosai_core::epub::{MathContent, MathDisplay, MathExpression};

        let expression = MathExpression::Fraction(
            Box::new(MathExpression::Token("a".into())),
            Box::new(MathExpression::SquareRoot(vec![MathExpression::Token(
                "b".into(),
            )])),
        );
        let table = ContentNode::Table {
            caption: Vec::new(),
            caption_style: None,
            row_groups: vec![TableRowGroup {
                kind: TableRowGroupKind::Body,
                rows: vec![TableRow {
                    cells: vec![TableCell {
                        id: None,
                        header: false,
                        scope: None,
                        headers: Vec::new(),
                        row_span: 1,
                        column_span: 1,
                        children: vec![ContentNode::Math {
                            content: MathContent {
                                display: MathDisplay::Block,
                                expression: Some(expression.clone()),
                                fallback: "(a)/(sqrt(b))".into(),
                            },
                            style: NodeStyle::default(),
                            link: None,
                        }],
                        block_starts: Vec::new(),
                        style: NodeStyle::default(),
                    }],
                }],
            }],
            style: NodeStyle::default(),
        };
        let font_size = 16.0;
        let outer_width = 360.0;
        let cell_width = outer_width - 2.0 * EPUB_TABLE_CELL_PADDING;
        let native_height =
            math_layout::layout_math_for_bounds(&expression, font_size, cell_width, 240.0)
                .expect("fixture math should fit the table cell")
                .height;
        let chars_per_line = (outer_width / (font_size * AVERAGE_CHARACTER_WIDTH)).floor() as usize;

        assert!(
            estimated_epub_compact_node_height(&table, chars_per_line, 20, font_size)
                >= native_height + 2.0 * EPUB_TABLE_CELL_PADDING,
            "table pagination must reserve the native display-math height painted in the cell"
        );
    }

    #[test]
    fn oversized_inline_math_flow_falls_back_before_pagination_layout() {
        use shosai_core::epub::render::TextSpan;
        use shosai_core::epub::{MathContent, MathDisplay, MathExpression};

        let mut spans = (0..256)
            .map(|_| TextSpan {
                text: "word ".into(),
                math: None,
                font_family: None,
                bold: false,
                italic: false,
                monospace: false,
                font_size_multiplier: 1.0,
                preserve_whitespace: false,
                link: None,
            })
            .collect::<Vec<_>>();
        spans.push(TextSpan {
            text: "(a)/(b)".into(),
            math: Some(MathContent {
                display: MathDisplay::Inline,
                expression: Some(MathExpression::Fraction(
                    Box::new(MathExpression::Token("a".into())),
                    Box::new(MathExpression::Token("b".into())),
                )),
                fallback: "(a)/(b)".into(),
            }),
            font_family: None,
            bold: false,
            italic: false,
            monospace: false,
            font_size_multiplier: 1.0,
            preserve_whitespace: false,
            link: Some("chapter.xhtml#proof".into()),
        });
        let pagination = pagination_inline_spans(
            &spans,
            16.0,
            360.0,
            500.0,
            shosai_core::epub::style::TextDirection::Ltr,
            None,
        );

        assert!(pagination.iter().all(|span| span.math.is_none()));
        assert_eq!(
            pagination.last().and_then(|span| span.link.as_deref()),
            Some("chapter.xhtml#proof"),
            "aggregate fallback must retain source links"
        );
        assert_eq!(spans_text_len(&pagination), spans_text_len(&spans));
    }

    #[test]
    fn standalone_math_pagination_uses_the_native_painted_height() {
        use shosai_core::epub::render::NodeStyle;
        use shosai_core::epub::{MathContent, MathDisplay, MathExpression};

        let expression = MathExpression::Fraction(
            Box::new(MathExpression::Token("a".into())),
            Box::new(MathExpression::SquareRoot(vec![MathExpression::Token(
                "b".into(),
            )])),
        );
        let node = ContentNode::Math {
            content: MathContent {
                display: MathDisplay::Block,
                expression: Some(expression.clone()),
                fallback: "(a)/(sqrt(b))".into(),
            },
            style: NodeStyle::default(),
            link: None,
        };
        let native = math_layout::layout_math_for_bounds(&expression, 20.0, 600.0, 700.0)
            .expect("supported standalone math should use native geometry");

        assert_eq!(
            measured_epub_compact_node_height(None, &node, 20.0, 600.0),
            Some(native.height),
            "pagination and painting must consume the same geometry"
        );
        assert_eq!(
            content_node_text_len(&node),
            "(a)/(sqrt(b))".chars().count(),
            "native presentation must not change shared source offsets"
        );
    }

    #[test]
    fn inline_math_is_atomic_and_uses_shared_geometry_during_pagination() {
        use shosai_core::epub::render::{NodeStyle, TextSpan};
        use shosai_core::epub::{MathContent, MathDisplay, MathExpression};

        let text_span = |text: &str| TextSpan {
            text: text.into(),
            math: None,
            font_family: None,
            bold: false,
            italic: false,
            monospace: false,
            font_size_multiplier: 1.0,
            preserve_whitespace: false,
            link: None,
        };
        let fallback = "(numerator)/(denominator)";
        let math_span = TextSpan {
            text: fallback.into(),
            math: Some(MathContent {
                display: MathDisplay::Inline,
                expression: Some(MathExpression::Fraction(
                    Box::new(MathExpression::Token("numerator".into())),
                    Box::new(MathExpression::Token("denominator".into())),
                )),
                fallback: fallback.into(),
            }),
            ..text_span("")
        };
        let spans = vec![
            text_span(&"before ".repeat(24)),
            math_span.clone(),
            text_span(&" after".repeat(24)),
        ];
        let plain = ContentNode::Paragraph(
            spans
                .iter()
                .cloned()
                .map(|mut span| {
                    span.math = None;
                    span
                })
                .collect(),
            NodeStyle::default(),
        );
        let paragraph = ContentNode::Paragraph(spans.clone(), NodeStyle::default());
        let pages = paginate_epub_chapter(
            std::slice::from_ref(&paragraph),
            None,
            16.0,
            1.6,
            Size::new(180.0, 150.0),
        );
        let fragments = pages.iter().flatten().collect::<Vec<_>>();
        let retained_math = fragments
            .iter()
            .filter_map(|page_node| match &page_node.node {
                ContentNode::Paragraph(spans, _) => spans.iter().find(|span| span.math.is_some()),
                _ => None,
            })
            .collect::<Vec<_>>();

        assert_eq!(retained_math, vec![&math_span]);
        assert_eq!(
            fragments
                .iter()
                .flat_map(|page_node| match &page_node.node {
                    ContentNode::Paragraph(spans, _) => spans,
                    _ => unreachable!(),
                })
                .map(|span| span.text.as_str())
                .collect::<String>(),
            spans
                .iter()
                .map(|span| span.text.as_str())
                .collect::<String>()
        );
        let mut expected_offset = 0;
        for page_node in fragments {
            assert_eq!(page_node.text_offset, expected_offset);
            expected_offset += content_node_text_len(&page_node.node);
        }
        let layout = layout_inline_math_span(&math_span, 16.0, 180.0, 150.0)
            .expect("supported inline math must retain native geometry");
        assert!(layout.height > 16.0 * TEXT_LINE_HEIGHT);
        let geometry_extra = layout.height - 16.0 * TEXT_LINE_HEIGHT;
        assert!(
            inline_math_height_reserve(&spans, 16.0, 180.0, 150.0)
                >= geometry_extra + 16.0 * INLINE_MATH_WRAP_SPACING,
            "wrapped native math must reserve inter-line clearance in addition to geometry"
        );
        let mut display_span = math_span.clone();
        display_span.math.as_mut().unwrap().display = MathDisplay::Block;
        assert!(layout_inline_math_span(&display_span, 16.0, 180.0, 150.0).is_none());
        assert!(
            estimated_epub_compact_node_height(&paragraph, 20, 10, 16.0)
                > estimated_epub_compact_node_height(&plain, 20, 10, 16.0)
        );
    }

    #[test]
    fn native_inline_admission_controls_atomic_pagination_and_reserve() {
        use shosai_core::epub::render::{NodeStyle, TextSpan};
        use shosai_core::epub::style::{TextAlignment, TextDirection};
        use shosai_core::epub::{MathContent, MathDisplay, MathExpression};

        let math_span = |expression: MathExpression, fallback: String| TextSpan {
            text: fallback.clone(),
            math: Some(MathContent {
                display: MathDisplay::Inline,
                expression: Some(expression),
                fallback,
            }),
            font_family: None,
            bold: false,
            italic: false,
            monospace: false,
            font_size_multiplier: 1.0,
            preserve_whitespace: false,
            link: None,
        };
        let fraction = || {
            math_span(
                MathExpression::Fraction(
                    Box::new(MathExpression::Token("a".into())),
                    Box::new(MathExpression::Token("b".into())),
                ),
                "(a)/(b)".into(),
            )
        };
        let retained_math = |node: &ContentNode| match node {
            ContentNode::Paragraph(spans, _) => {
                spans.iter().filter(|span| span.math.is_some()).count()
            }
            _ => 0,
        };
        let page_size = Size::new(180.0, 120.0);
        let fallback_cases = [
            (
                fraction(),
                NodeStyle {
                    direction: TextDirection::Rtl,
                    ..Default::default()
                },
            ),
            (
                fraction(),
                NodeStyle {
                    text_align: Some(TextAlignment::Justify),
                    ..Default::default()
                },
            ),
            (
                math_span(
                    MathExpression::Token("overwide".repeat(80)),
                    "overwide".repeat(80),
                ),
                NodeStyle::default(),
            ),
            (
                math_span(
                    MathExpression::Fraction(
                        Box::new(MathExpression::Fraction(
                            Box::new(MathExpression::Token("a".into())),
                            Box::new(MathExpression::Token("b".into())),
                        )),
                        Box::new(MathExpression::Fraction(
                            Box::new(MathExpression::Token("c".into())),
                            Box::new(MathExpression::Token("d".into())),
                        )),
                    ),
                    "((a)/(b))/((c)/(d))".into(),
                ),
                NodeStyle::default(),
            ),
            (
                math_span(MathExpression::Token("\u{10ffff}".into()), "missing".into()),
                NodeStyle::default(),
            ),
        ];

        for (span, style) in fallback_cases {
            let height = if span.text == "((a)/(b))/((c)/(d))" {
                20.0
            } else {
                page_size.height
            };
            let pages = paginate_epub_chapter(
                &[ContentNode::Paragraph(vec![span], style)],
                None,
                16.0,
                1.6,
                Size::new(page_size.width, height),
            );
            assert_eq!(
                pages
                    .iter()
                    .flatten()
                    .map(|page| retained_math(&page.node))
                    .sum::<usize>(),
                0,
                "fallback presentation must remain splittable instead of carrying atomic geometry"
            );
        }

        let native = ContentNode::Paragraph(vec![fraction()], NodeStyle::default());
        let native_pages = paginate_epub_chapter(&[native], None, 16.0, 1.6, page_size);
        assert_eq!(
            native_pages
                .iter()
                .flatten()
                .map(|page| retained_math(&page.node))
                .sum::<usize>(),
            1,
            "admitted native geometry must remain one atomic span"
        );
    }

    #[test]
    fn deeply_nested_inline_fraction_uses_readable_fallback() {
        use shosai_core::epub::render::TextSpan;
        use shosai_core::epub::{MathContent, MathDisplay, MathExpression};

        let token = |text: &str| MathExpression::Token(text.into());
        let fraction = |top, bottom| MathExpression::Fraction(Box::new(top), Box::new(bottom));
        let expression = fraction(
            fraction(
                fraction(token("a"), token("b")),
                fraction(token("c"), token("d")),
            ),
            fraction(
                fraction(token("e"), token("f")),
                fraction(token("g"), token("h")),
            ),
        );
        let fallback = "(((a)/(b))/((c)/(d)))/(((e)/(f))/((g)/(h)))";
        let span = TextSpan {
            text: fallback.into(),
            math: Some(MathContent {
                display: MathDisplay::Inline,
                expression: Some(expression),
                fallback: fallback.into(),
            }),
            font_family: None,
            bold: false,
            italic: false,
            monospace: false,
            font_size_multiplier: 1.0,
            preserve_whitespace: false,
            link: None,
        };

        assert!(
            layout_inline_math_span(&span, 20.0, 388.0, 500.0).is_none(),
            "inline geometry spanning several text lines must use readable fallback even when it fits the page"
        );
        let pages = paginate_epub_chapter(
            &[ContentNode::Paragraph(vec![span], Default::default())],
            None,
            20.0,
            1.6,
            Size::new(388.0, 500.0),
        );
        assert!(pages.iter().flatten().all(|page| {
            matches!(
                &page.node,
                ContentNode::Paragraph(spans, _)
                    if spans.iter().all(|span| span.math.is_none())
            )
        }));
    }

    #[test]
    fn paragraph_pagination_accounts_for_inline_geometry_at_page_boundaries() {
        use shosai_core::epub::render::{NodeStyle, TextSpan};
        use shosai_core::epub::{MathContent, MathDisplay, MathExpression};

        let plain = |text: String| TextSpan {
            text,
            math: None,
            font_family: None,
            bold: false,
            italic: false,
            monospace: false,
            font_size_multiplier: 1.0,
            preserve_whitespace: false,
            link: None,
        };
        let mut spans = Vec::new();
        for index in 0..8 {
            spans.push(plain(format!("segment {index} before ")));
            spans.push(TextSpan {
                text: "(a)/(b)".into(),
                math: Some(MathContent {
                    display: MathDisplay::Inline,
                    expression: Some(MathExpression::Fraction(
                        Box::new(MathExpression::Token("a".into())),
                        Box::new(MathExpression::Token("b".into())),
                    )),
                    fallback: "(a)/(b)".into(),
                }),
                ..plain(String::new())
            });
            spans.push(plain(" after. ".into()));
        }
        let plain_spans = spans
            .iter()
            .cloned()
            .map(|mut span| {
                span.math = None;
                span
            })
            .collect::<Vec<_>>();
        let source = spans
            .iter()
            .map(|span| span.text.as_str())
            .collect::<String>();
        let size = Size::new(180.0, 120.0);
        let pages = paginate_epub_chapter(
            &[ContentNode::Paragraph(spans, NodeStyle::default())],
            None,
            20.0,
            1.6,
            size,
        );
        let plain_pages = paginate_epub_chapter(
            &[ContentNode::Paragraph(plain_spans, NodeStyle::default())],
            None,
            20.0,
            1.6,
            size,
        );

        assert!(
            pages.len() > plain_pages.len(),
            "native geometry and wrap clearance must affect actual page placement"
        );
        let fragments = pages.iter().flatten().collect::<Vec<_>>();
        assert_eq!(
            fragments
                .iter()
                .flat_map(|page| match &page.node {
                    ContentNode::Paragraph(spans, _) => spans,
                    _ => unreachable!(),
                })
                .map(|span| span.text.as_str())
                .collect::<String>(),
            source
        );
        let mut expected_offset = 0;
        for page in fragments {
            assert_eq!(page.text_offset, expected_offset);
            expected_offset += content_node_text_len(&page.node);
        }
    }

    #[test]
    fn blockquote_splits_do_not_duplicate_fallback_math_metadata() {
        use shosai_core::epub::render::{NodeStyle, TextSpan};
        use shosai_core::epub::{MathContent, MathDisplay, MathExpression};

        let fallback = "fallback ".repeat(80);
        let math = TextSpan {
            text: fallback.clone(),
            math: Some(MathContent {
                display: MathDisplay::Inline,
                expression: Some(MathExpression::Token(fallback.clone())),
                fallback: fallback.clone(),
            }),
            font_family: None,
            bold: false,
            italic: false,
            monospace: false,
            font_size_multiplier: 1.0,
            preserve_whitespace: false,
            link: None,
        };
        let pages = paginate_epub_chapter(
            &[ContentNode::BlockQuote {
                children: vec![ContentNode::Paragraph(vec![math], NodeStyle::default())],
                style: NodeStyle::default(),
            }],
            None,
            16.0,
            1.6,
            Size::new(180.0, 120.0),
        );
        let mut text = String::new();
        let mut retained_math = 0;
        for page in pages.iter().flatten() {
            let ContentNode::BlockQuote { children, .. } = &page.node else {
                unreachable!();
            };
            for child in children {
                if let ContentNode::Paragraph(spans, _) = child {
                    text.extend(spans.iter().map(|span| span.text.as_str()));
                    retained_math += spans.iter().filter(|span| span.math.is_some()).count();
                }
            }
        }
        assert_eq!(text, fallback);
        assert_eq!(
            retained_math, 0,
            "splittable fallback must not clone native metadata"
        );
    }

    #[test]
    fn unsupported_or_overwide_math_keeps_the_readable_text_path() {
        use shosai_core::epub::render::NodeStyle;
        use shosai_core::epub::{MathContent, MathDisplay, MathExpression};

        let unsupported = ContentNode::Math {
            content: MathContent {
                display: MathDisplay::Block,
                expression: None,
                fallback: "readable fallback".into(),
            },
            style: NodeStyle::default(),
            link: None,
        };
        let overwide = ContentNode::Math {
            content: MathContent {
                display: MathDisplay::Block,
                expression: Some(MathExpression::Token("wide expression".into())),
                fallback: "wide expression".into(),
            },
            style: NodeStyle::default(),
            link: None,
        };

        assert!(
            estimated_epub_compact_node_height(&unsupported, 40, 20, 20.0) > 0.0,
            "unsupported math must remain measurable through its fallback"
        );
        let ContentNode::Math { content, .. } = &overwide else {
            unreachable!();
        };
        assert!(
            math_layout::layout_math_for_bounds(
                content.expression.as_ref().unwrap(),
                20.0,
                1.0,
                700.0,
            )
            .is_none()
        );
        assert!(estimated_epub_compact_node_height(&overwide, 1, 20, 20.0) > 0.0);
    }

    #[test]
    fn dense_math_sequence_moves_complete_matrix_and_fallback_between_pages() {
        use shosai_core::epub::render::{NodeStyle, TextSpan};
        use shosai_core::epub::{MathContent, MathDisplay, MathExpression};

        let label = |text: &str| {
            ContentNode::Paragraph(
                vec![TextSpan {
                    text: text.into(),
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
            )
        };
        let math = |expression: Option<MathExpression>, fallback: &str| ContentNode::Math {
            content: MathContent {
                display: MathDisplay::Block,
                expression,
                fallback: fallback.into(),
            },
            style: NodeStyle {
                font_size_multiplier: Some(1.5),
                ..NodeStyle::default()
            },
            link: None,
        };
        let token = |text: &str| MathExpression::Token(text.into());
        let matrix = MathExpression::Fenced {
            open: "(".into(),
            close: ")".into(),
            content: vec![MathExpression::Table(vec![
                vec![token("1"), token("0")],
                vec![token("0"), token("1")],
            ])],
        };
        let nodes = vec![
            label("Native MathML geometry — fraction:"),
            math(
                Some(MathExpression::Fraction(
                    Box::new(MathExpression::Row(vec![
                        token("a"),
                        token("+"),
                        token("b"),
                    ])),
                    Box::new(MathExpression::Row(vec![
                        token("c"),
                        token("+"),
                        token("d"),
                    ])),
                )),
                "(a+b)/(c+d)",
            ),
            label("Indexed root and sub/superscript:"),
            math(
                Some(MathExpression::Row(vec![
                    MathExpression::Root(Box::new(token("x")), Box::new(token("3"))),
                    token("+"),
                    MathExpression::SubSuperscript {
                        base: Box::new(token("y")),
                        subscript: Box::new(token("i")),
                        superscript: Box::new(token("2")),
                    },
                ])),
                "root(x, 3) + y_i^2",
            ),
            label("Fence:"),
            math(
                Some(MathExpression::Fenced {
                    open: "[".into(),
                    close: "]".into(),
                    content: vec![MathExpression::Row(vec![
                        token("p"),
                        token("+"),
                        token("q"),
                    ])],
                }),
                "[p + q]",
            ),
            label("Fenced 2 x 2 matrix:"),
            math(Some(matrix.clone()), "(1 0; 0 1)"),
            label("Unsupported case remains readable:"),
            math(None, "Readable unsupported fallback"),
        ];
        let page_size = Size::new(420.0, 500.0);
        let pages = paginate_epub_chapter(&nodes, None, 16.0, 1.6, page_size);

        assert!(
            pages.len() > 1,
            "dense fixture must exercise a page boundary"
        );
        assert_eq!(
            pages.iter().map(Vec::len).sum::<usize>(),
            nodes.len(),
            "pagination must retain every label, expression, and fallback"
        );
        let mut expected_offset = 0;
        for (page_node, source_node) in pages.iter().flatten().zip(&nodes) {
            assert_eq!(page_node.text_offset, expected_offset);
            assert_eq!(&page_node.node, source_node);
            expected_offset += content_node_text_len(source_node) + 1;
        }
        let matrix_page = pages
            .iter()
            .position(|page| {
                page.iter().any(|node| {
                    matches!(
                        &node.node,
                        ContentNode::Math { content, .. }
                            if content.expression.as_ref() == Some(&matrix)
                    )
                })
            })
            .expect("matrix must remain on one page");
        assert!(matches!(
            pages[matrix_page].as_slice(),
            [
                PageNode {
                    node: ContentNode::Paragraph(spans, _),
                    ..
                },
                PageNode {
                    node: ContentNode::Math { content, .. },
                    ..
                },
                ..
            ] if spans.iter().any(|span| span.text == "Fenced 2 x 2 matrix:")
                && content.expression.as_ref() == Some(&matrix)
        ));
        let matrix_layout = math_layout::layout_math_for_bounds(&matrix, 24.0, 420.0, 500.0)
            .expect("matrix must retain native geometry");
        assert!(matrix_layout.primitives.iter().all(|primitive| {
            primitive.x >= 0.0
                && primitive.y >= 0.0
                && primitive.x + primitive.width <= matrix_layout.width
                && primitive.y + primitive.height <= matrix_layout.height
        }));
        for value in ["1", "0"] {
            assert!(matrix_layout.primitives.iter().any(|primitive| {
                matches!(&primitive.kind, math_layout::MathPrimitiveKind::Text(text) if text == value)
            }));
        }
        let zero_rows = matrix_layout
            .primitives
            .iter()
            .filter(|primitive| {
                matches!(&primitive.kind, math_layout::MathPrimitiveKind::Text(text) if text == "0")
            })
            .map(|primitive| primitive.y)
            .collect::<Vec<_>>();
        assert_eq!(zero_rows.len(), 2);
        assert_ne!(
            zero_rows[0], zero_rows[1],
            "both matrix rows must be positioned"
        );
        assert!(
            pages[matrix_page..]
                .iter()
                .any(|page| page.iter().any(|node| {
                    matches!(
                        &node.node,
                        ContentNode::Math { content, .. }
                            if content.fallback == "Readable unsupported fallback"
                    )
                }))
        );
    }

    #[test]
    fn paginated_tables_split_only_between_complete_rowspan_bands() {
        let epub = shosai_core::epub::EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/epub-conformance/table.epub").to_vec(),
        )
        .expect("table fixture should be a valid EPUB");
        let table = epub
            .presentation()
            .chapter(0)
            .unwrap()
            .nodes()
            .iter()
            .find(|node| matches!(node, ContentNode::Table { .. }))
            .expect("fixture must retain a semantic table");
        let expected_rows = match table {
            ContentNode::Table { row_groups, .. } => row_groups
                .iter()
                .map(|group| group.rows.len())
                .sum::<usize>(),
            _ => unreachable!(),
        };

        let pages = paginate_epub_chapter(
            std::slice::from_ref(table),
            None,
            16.0,
            1.4,
            Size::new(240.0, 72.0),
        );
        let fragments = pages
            .iter()
            .flatten()
            .map(|page_node| (&page_node.node, page_node.text_offset))
            .collect::<Vec<_>>();

        assert!(pages.len() > 1, "tall tables must fragment by row bands");
        assert_eq!(
            fragments
                .iter()
                .map(|(node, _)| match node {
                    ContentNode::Table { row_groups, .. } => row_groups
                        .iter()
                        .map(|group| group.rows.len())
                        .sum::<usize>(),
                    other => panic!("expected table fragment, got {other:?}"),
                })
                .sum::<usize>(),
            expected_rows
        );
        for (node, _) in &fragments {
            let ContentNode::Table { row_groups, .. } = node else {
                unreachable!();
            };
            for group in row_groups {
                for (row_index, row) in group.rows.iter().enumerate() {
                    let required_rows = row
                        .cells
                        .iter()
                        .map(|cell| {
                            if cell.row_span == 0 {
                                group.rows.len() - row_index
                            } else {
                                usize::from(cell.row_span)
                            }
                        })
                        .max()
                        .unwrap_or(1);
                    assert!(row_index + required_rows <= group.rows.len());
                }
            }
        }
        for pair in fragments.windows(2) {
            assert_eq!(pair[1].1, pair[0].1 + content_node_text_len(pair[0].0));
        }
        let (last, last_offset) = fragments.last().expect("table must produce fragments");
        assert_eq!(
            last_offset + content_node_text_len(last),
            content_node_text_len(table)
        );
    }

    #[test]
    fn table_height_estimation_includes_rendered_padding_and_spacing() {
        let one_row = one_line_table(1);
        let height = estimated_epub_compact_node_height(&one_row, 40, 20, 16.0);

        assert!((height - (16.0 * TEXT_LINE_HEIGHT + 12.0)).abs() < 0.001);
    }

    #[test]
    fn fitting_rowspan_bands_share_one_paginated_table_surface() {
        let table = one_line_table(3);
        let pages = paginate_epub_chapter(
            std::slice::from_ref(&table),
            None,
            16.0,
            1.4,
            Size::new(360.0, 300.0),
        );
        let fragments = pages
            .iter()
            .flatten()
            .filter(|page_node| matches!(page_node.node, ContentNode::Table { .. }))
            .collect::<Vec<_>>();

        assert_eq!(fragments.len(), 1);
        assert_eq!(
            content_node_text_len(&fragments[0].node),
            content_node_text_len(&table)
        );
    }

    #[test]
    fn narrow_table_layout_overflows_without_unbounded_column_amplification() {
        let epub = shosai_core::epub::EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/epub-conformance/table.epub").to_vec(),
        )
        .expect("table fixture should be a valid EPUB");
        let ContentNode::Table { row_groups, .. } = epub
            .presentation()
            .chapter(0)
            .unwrap()
            .nodes()
            .iter()
            .find(|node| matches!(node, ContentNode::Table { .. }))
            .expect("fixture must retain a semantic table")
        else {
            unreachable!();
        };

        assert_eq!(epub_table_layout_width(row_groups, 240.0), 360.0);
        assert_eq!(epub_table_layout_width(row_groups, 600.0), 600.0);

        let mut amplified = row_groups.clone();
        amplified[0].rows[0].cells[0].column_span = 1_000;
        assert_eq!(epub_table_layout_width(&amplified, 240.0), 4_096.0);
    }

    #[test]
    fn epub_paginator_splits_long_paragraphs_without_losing_formatting() {
        let text = "This is a linked sentence that should wrap cleanly. ".repeat(30);
        let spans = vec![shosai_core::epub::render::TextSpan {
            text: text.clone(),
            math: None,
            font_family: None,
            bold: true,
            italic: false,
            monospace: false,
            font_size_multiplier: 1.0,
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
    fn epub_paginator_bounds_pathological_text_geometry_without_losing_content() {
        let text = "é".repeat(MAX_EPUB_PAGES + 20);
        let spans = vec![shosai_core::epub::render::TextSpan {
            text: text.clone(),
            math: None,
            font_family: None,
            bold: true,
            italic: true,
            monospace: true,
            font_size_multiplier: 1.0,
            preserve_whitespace: false,
            link: None,
        }];
        let style = shosai_core::epub::render::NodeStyle {
            font_size_multiplier: Some(1_000_000_000.0),
            ..Default::default()
        };

        let pages = paginate_epub_chapter(
            &[ContentNode::Paragraph(spans, style)],
            None,
            16.0,
            1.6,
            Size::new(240.0, 180.0),
        );

        assert_eq!(pages.len(), MAX_EPUB_PAGES);
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
        assert!(chunks.iter().all(|span| {
            span.bold && span.italic && span.monospace && span.font_size_multiplier == 1.0
        }));
        assert_eq!(chunks.last().unwrap().text.chars().count(), 20);
        assert_eq!(pages.last().unwrap().len(), 2);
        assert_eq!(pages.last().unwrap()[1].text_offset, MAX_EPUB_PAGES);
    }

    #[test]
    fn epub_pagination_budget_is_shared_across_blockquotes_and_chapters() {
        let paragraph = |character: char| {
            ContentNode::Paragraph(
                vec![shosai_core::epub::render::TextSpan {
                    text: character.to_string().repeat(20),
                    math: None,
                    font_family: None,
                    bold: false,
                    italic: false,
                    monospace: false,
                    font_size_multiplier: 1.0,
                    preserve_whitespace: false,
                    link: None,
                }],
                shosai_core::epub::render::NodeStyle {
                    font_size_multiplier: Some(1_000_000_000.0),
                    ..Default::default()
                },
            )
        };
        let first_chapter = vec![
            ContentNode::BlockQuote {
                children: vec![paragraph('a')],
                style: Default::default(),
            },
            ContentNode::BlockQuote {
                children: vec![paragraph('b')],
                style: Default::default(),
            },
        ];
        let second_chapter = vec![paragraph('c')];
        let mut budget = EpubPaginationBudget {
            remaining_page_breaks: 3,
        };

        let first_pages = paginate_epub_chapter_with_budget(
            &first_chapter,
            None,
            16.0,
            1.6,
            Size::new(240.0, 180.0),
            None,
            &mut budget,
        );
        let second_pages = paginate_epub_chapter_with_budget(
            &second_chapter,
            None,
            16.0,
            1.6,
            Size::new(240.0, 180.0),
            None,
            &mut budget,
        );

        assert_eq!(first_pages.len() + second_pages.len(), 2);
        assert_eq!(budget.remaining_page_breaks, 0);
        assert!(
            first_pages.iter().flatten().count() + second_pages.iter().flatten().count() <= 7,
            "exhausted recursive pagination must retain source nodes without fresh fragmentation"
        );
        let text = first_pages
            .iter()
            .chain(&second_pages)
            .flat_map(|page| page.iter().map(|node| node.node.clone()))
            .collect::<Vec<_>>();
        let text = shosai_core::search::extract_text_from_nodes(&text)
            .chars()
            .filter(|character| matches!(character, 'a' | 'b' | 'c'))
            .collect::<String>();
        assert_eq!(
            text,
            format!("{}{}{}", "a".repeat(20), "b".repeat(20), "c".repeat(20))
        );
    }

    #[test]
    fn epub_paginator_splits_long_lists_without_losing_items() {
        let items = (0..30)
            .map(|index| {
                vec![shosai_core::epub::render::TextSpan {
                    text: format!("List item {index}"),
                    math: None,
                    font_family: None,
                    bold: false,
                    italic: false,
                    monospace: false,
                    font_size_multiplier: 1.0,
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
                    math: None,
                    font_family: None,
                    bold: false,
                    italic: false,
                    monospace: false,
                    font_size_multiplier: 1.0,
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
                        math: None,
                        font_family: None,
                        bold: false,
                        italic: false,
                        monospace: false,
                        font_size_multiplier: 1.0,
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
                        math: None,
                        font_family: None,
                        bold: false,
                        italic: false,
                        monospace: false,
                        font_size_multiplier: 1.0,
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
                    math: None,
                    font_family: None,
                    bold: false,
                    italic: false,
                    monospace: false,
                    font_size_multiplier: 1.0,
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
                    math: None,
                    font_family: None,
                    bold: false,
                    italic: false,
                    monospace: false,
                    font_size_multiplier: 1.0,
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
                spans: vec![shosai_core::epub::render::TextSpan {
                    text: "Previous chapter".to_string(),
                    math: None,
                    font_family: None,
                    bold: true,
                    italic: false,
                    monospace: false,
                    font_size_multiplier: 1.0,
                    preserve_whitespace: false,
                    link: None,
                }],
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
                        math: None,
                        font_family: None,
                        bold: false,
                        italic: false,
                        monospace: false,
                        font_size_multiplier: 1.0,
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
                    math: None,
                    font_family: None,
                    bold: false,
                    italic: false,
                    monospace: false,
                    font_size_multiplier: 1.0,
                    preserve_whitespace: false,
                    link: None,
                }],
                Default::default(),
            )
        }

        fn first_text(node: &ContentNode) -> &str {
            match node {
                ContentNode::Heading { spans, .. } => &spans[0].text,
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
                    math: None,
                    font_family: None,
                    bold: false,
                    italic: false,
                    monospace: false,
                    font_size_multiplier: 1.0,
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
                math: None,
                font_family: None,
                bold: false,
                italic: false,
                monospace: false,
                font_size_multiplier: 1.0,
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
                math: None,
                font_family: None,
                bold: false,
                italic: false,
                monospace: false,
                font_size_multiplier: 1.0,
                preserve_whitespace: false,
                link: None,
            }],
            style,
        )];

        let pages = paginate_epub_chapter(&nodes, None, 16.0, 1.6, Size::new(240.0, 110.0));

        assert!(pages.len() > 1, "enlarged text must use its scaled width");
    }

    #[test]
    fn epub_paginator_uses_inherited_list_font_sizes_for_geometry() {
        let list = |scale| {
            ContentNode::UnorderedList(
                (0..4)
                    .map(|_| {
                        vec![shosai_core::epub::render::TextSpan {
                            text: "A list item with enough text to wrap across lines".to_string(),
                            math: None,
                            font_family: None,
                            bold: false,
                            italic: false,
                            monospace: false,
                            font_size_multiplier: scale,
                            preserve_whitespace: false,
                            link: None,
                        }]
                    })
                    .collect(),
            )
        };
        let paginate =
            |scale| paginate_epub_chapter(&[list(scale)], None, 16.0, 1.6, Size::new(240.0, 180.0));

        let small = paginate(0.5);
        let normal = paginate(1.0);
        let large = paginate(2.0);

        assert!(
            small.len() < normal.len(),
            "small list text should pack tighter"
        );
        assert!(
            normal.len() < large.len(),
            "large list text should consume more pages"
        );
        let ContentNode::UnorderedList(items) = list(0.5) else {
            unreachable!()
        };
        assert_eq!(spans_font_scale(&items[0]), 0.5);
    }

    #[test]
    fn epub_paginator_places_images_on_their_own_page() {
        let pages = paginate_epub_chapter(
            &[
                ContentNode::Paragraph(
                    vec![shosai_core::epub::render::TextSpan {
                        text: "Text before the image".to_string(),
                        math: None,
                        font_family: None,
                        bold: false,
                        italic: false,
                        monospace: false,
                        font_size_multiplier: 1.0,
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
    fn measured_paragraph_splits_preserve_unicode_clusters_text_and_offsets() {
        let text = "Aé 👩\u{200d}🔬 B";
        let spans = vec![shosai_core::epub::render::TextSpan {
            text: text.into(),
            math: None,
            font_family: Some("Book Alias".into()),
            bold: false,
            italic: false,
            monospace: false,
            font_size_multiplier: 1.0,
            preserve_whitespace: false,
            link: None,
        }];
        let layout = EpubTextLayout {
            width: 100.0,
            height: 40.0,
            lines: vec![
                shosai_core::epub::EpubTextLine {
                    top: 0.0,
                    width: 40.0,
                    rtl: false,
                    scalars: 0..3,
                    pixel_width: 0,
                    pixel_height: 20,
                    rgba: Vec::new(),
                },
                shosai_core::epub::EpubTextLine {
                    top: 20.0,
                    width: 60.0,
                    rtl: false,
                    scalars: 3..8,
                    pixel_width: 0,
                    pixel_height: 20,
                    rgba: Vec::new(),
                },
            ],
            links: Vec::new(),
        };
        let measured_lengths = std::cell::RefCell::new(Vec::new());
        let measure = |spans: &[shosai_core::epub::render::TextSpan]| {
            let scalars = spans_text_len(spans);
            measured_lengths.borrow_mut().push(scalars);
            if scalars == 8 {
                return Some(layout.clone());
            }
            Some(EpubTextLayout {
                width: 60.0,
                height: 20.0,
                lines: vec![shosai_core::epub::EpubTextLine {
                    top: 0.0,
                    width: 60.0,
                    rtl: false,
                    scalars: 0..scalars,
                    pixel_width: 0,
                    pixel_height: 20,
                    rgba: Vec::new(),
                }],
                links: Vec::new(),
            })
        };
        let mut pages = vec![Vec::new()];
        let mut remaining = 25.0;
        assert!(paginate_measured_paragraph(
            &spans,
            &Default::default(),
            &measure,
            10,
            4.0,
            25.0,
            false,
            &mut pages,
            &mut remaining,
            &mut EpubPaginationBudget::default(),
        ));

        let chunks = pages
            .iter()
            .flat_map(|page| page.iter())
            .map(|node| {
                let ContentNode::Paragraph(spans, _) = &node.node else {
                    panic!("measured paragraph must remain a paragraph");
                };
                (
                    node.text_offset,
                    spans
                        .iter()
                        .map(|span| span.text.as_str())
                        .collect::<String>(),
                )
            })
            .collect::<Vec<_>>();
        assert_eq!(
            chunks,
            vec![(10, "Aé ".into()), (13, "👩\u{200d}🔬 B".into())]
        );
        assert_eq!(
            chunks
                .iter()
                .map(|(_, text)| text.as_str())
                .collect::<String>(),
            text
        );
        assert!(
            measured_lengths
                .borrow()
                .windows(3)
                .any(|calls| calls == [8, 3, 5])
        );
    }

    #[test]
    fn measured_pagination_bounds_each_native_shaping_request() {
        let text = "x".repeat(EPUB_PAGINATION_SHAPE_CHUNK * 3 + 17);
        let spans = vec![shosai_core::epub::render::TextSpan {
            text: text.clone(),
            math: None,
            font_family: Some("Book".into()),
            bold: false,
            italic: false,
            monospace: false,
            font_size_multiplier: 1.0,
            preserve_whitespace: false,
            link: None,
        }];
        let measured = std::cell::RefCell::new(Vec::new());
        let measure = |spans: &[shosai_core::epub::render::TextSpan]| {
            let count = spans_text_len(spans);
            measured.borrow_mut().push(count);
            Some(EpubTextLayout {
                width: 100.0,
                height: count as f32 * 20.0,
                lines: (0..count)
                    .map(|index| shosai_core::epub::EpubTextLine {
                        top: index as f32 * 20.0,
                        width: 100.0,
                        rtl: false,
                        scalars: index..index + 1,
                        pixel_width: 0,
                        pixel_height: 20,
                        rgba: Vec::new(),
                    })
                    .collect(),
                links: Vec::new(),
            })
        };
        let mut pages = vec![Vec::new()];
        let mut remaining = 20.0;
        assert!(paginate_measured_paragraph(
            &spans,
            &Default::default(),
            &measure,
            0,
            0.0,
            20.0,
            false,
            &mut pages,
            &mut remaining,
            &mut EpubPaginationBudget::default(),
        ));

        assert!(
            measured
                .borrow()
                .iter()
                .all(|count| *count <= EPUB_PAGINATION_SHAPE_CHUNK)
        );
        assert!(
            measured.borrow().iter().sum::<usize>() <= text.len() * 4 + EPUB_PAGINATION_SHAPE_CHUNK,
            "overlapping native suffix work must remain linear in paragraph size"
        );
        let retained = pages
            .iter()
            .flatten()
            .filter_map(|page| match &page.node {
                ContentNode::Paragraph(spans, _) => Some(
                    spans
                        .iter()
                        .map(|span| span.text.as_str())
                        .collect::<String>(),
                ),
                _ => None,
            })
            .collect::<String>();
        assert_eq!(retained, text);
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
