use std::collections::HashMap;

use iced::widget::{column, container, image, rich_text, row, scrollable, sensor, span, svg, text};
use iced::{Element, Font, Length};
use shosai_core::epub::EpubDoc;
use shosai_core::epub::render::ContentNode;
use shosai_core::epub::{
    EpubFontBook, EpubTextAlign, EpubTextDirection, EpubTextHighlight, EpubTextRequest, EpubTextRun,
};

use super::{
    BOOKMARKS_PANEL_WIDTH, EPUB_BLOCKQUOTE_SPACING, EPUB_PAGE_NUMBER_SIZE, EPUB_TABLE_CELL_PADDING,
    EPUB_TABLE_CELL_SPACING, EPUB_TABLE_ROW_SPACING, EpubImageHandle, Message, OpenDocument,
    PAGE_GUTTER, SearchHighlight, State, continuous_epub_node_id, continuous_epub_title_id,
    continuous_item_id, continuous_scroll_id, epub_page_size, epub_uses_spread, epub_visible_pages,
    search_highlight_models_for_page, uses_compact_reader_layout,
};
use crate::epub::{
    content_node_text_len, content_starts_with_heading, spans_font_scale, spans_text_len,
};
use crate::i18n::I18n;
use crate::theme::ReaderPalette;

pub(super) fn continuous_epub_content_view<'a>(
    state: &'a State,
    doc: &'a EpubDoc,
    tab_id: u64,
    activation: u64,
) -> Element<'a, Message> {
    let mut chapters = column![].spacing(32).padding(20).width(Length::Fill);
    for (chapter_index, presentation) in doc.presentation().chapters().iter().enumerate() {
        let nodes = presentation.nodes();
        let mut chapter = column![];
        if let Some(title) = doc
            .chapter(chapter_index)
            .and_then(|chapter| chapter.title.as_ref())
            .filter(|title| !content_starts_with_heading(nodes, title))
        {
            chapter = chapter.push(
                container(
                    text(title.clone())
                        .size(state.font_size * 1.5)
                        .color(state.theme.text_color()),
                )
                .id(continuous_epub_title_id(tab_id, activation, chapter_index)),
            );
        }
        let highlights = search_highlight_models_for_page(state, chapter_index);
        let mut text_offset = 0;
        for (node_index, node) in nodes.iter().enumerate() {
            let before = crate::epub::epub_node_boundary_spacing(
                nodes,
                node_index,
                state.font_size,
                state.font_size * state.line_spacing,
            );
            chapter = chapter.push(
                container(render_content_node(
                    node,
                    &state.i18n,
                    state.font_size,
                    state.theme.palette(),
                    &state.epub_image_handles,
                    false,
                    continuous_epub_content_width(
                        state.window_size.width,
                        state.show_bookmarks_panel,
                    ),
                    None,
                    None,
                    text_offset,
                    &highlights,
                    Some(doc.fonts()),
                    state.window_scale_factor,
                ))
                .id(continuous_epub_node_id(
                    tab_id,
                    activation,
                    chapter_index,
                    node_index,
                ))
                .padding(iced::Padding {
                    top: before,
                    ..iced::Padding::ZERO
                })
                .width(Length::Fill),
            );
            text_offset += content_node_text_len(node) + 1;
        }
        let after = crate::epub::epub_node_boundary_spacing(
            nodes,
            nodes.len(),
            state.font_size,
            state.font_size * state.line_spacing,
        );
        chapter = chapter.push(iced::widget::Space::new().height(after));
        chapters = chapters.push(
            sensor(
                container(chapter.width(Length::Fill))
                    .id(continuous_item_id(tab_id, activation, chapter_index))
                    .width(Length::Fill),
            )
            .key(chapter_index)
            .on_show(move |_| Message::ContinuousItemVisibility {
                tab_id,
                activation,
                page: chapter_index,
                visible: true,
            })
            .on_hide(Message::ContinuousItemVisibility {
                tab_id,
                activation,
                page: chapter_index,
                visible: false,
            }),
        );
    }
    chapters = chapters.push(iced::widget::Space::new().height(state.continuous_tail_extent));
    let content = container(chapters)
        .max_width(800)
        .width(Length::Fill)
        .center_x(Length::Fill);
    let background = state.theme.background();
    container(
        scrollable(content)
            .id(continuous_scroll_id(tab_id, activation))
            .on_scroll(move |viewport| Message::ContinuousScrolled {
                tab_id,
                activation,
                offset: viewport.absolute_offset().y,
            })
            .width(Length::Fill)
            .height(Length::Fill),
    )
    .style(move |_| container::Style {
        background: Some(iced::Background::Color(background)),
        ..Default::default()
    })
    .width(Length::Fill)
    .height(Length::Fill)
    .into()
}

fn continuous_epub_content_width(window_width: f32, show_bookmarks_panel: bool) -> f32 {
    let panel_width = if show_bookmarks_panel && !uses_compact_reader_layout(window_width) {
        BOOKMARKS_PANEL_WIDTH
    } else {
        0.0
    };
    ((window_width - panel_width).min(800.0) - 40.0).max(120.0)
}

pub(super) fn cache_epub_image_handles<'a, F>(
    handles: &mut HashMap<String, EpubImageHandle>,
    nodes: impl IntoIterator<Item = &'a ContentNode>,
    resource_bytes: &F,
) where
    F: Fn(&str) -> Option<&'a [u8]>,
{
    for node in nodes {
        match node {
            ContentNode::Image { src, kind, .. } => {
                if handles.contains_key(src) {
                    continue;
                }
                let Some(data) = resource_bytes(src) else {
                    continue;
                };
                let handle = match kind {
                    Some(shosai_core::epub::render::ImageKind::Svg) => {
                        EpubImageHandle::Svg(svg::Handle::from_memory(data.to_vec()))
                    }
                    _ => {
                        let Ok(decoded) = ::image::load_from_memory(data) else {
                            continue;
                        };
                        let rgba = decoded.to_rgba8();
                        let (width, height) = rgba.dimensions();
                        EpubImageHandle::Raster(image::Handle::from_rgba(
                            width,
                            height,
                            rgba.into_raw(),
                        ))
                    }
                };
                handles.insert(src.clone(), handle);
            }
            ContentNode::BlockQuote { children, .. } | ContentNode::Figure { children, .. } => {
                cache_epub_image_handles(handles, children, resource_bytes);
            }
            ContentNode::Table { row_groups, .. } => {
                for cell in row_groups
                    .iter()
                    .flat_map(|group| &group.rows)
                    .flat_map(|row| &row.cells)
                {
                    cache_epub_image_handles(handles, &cell.children, resource_bytes);
                }
            }
            _ => {}
        }
    }
}

pub(super) fn epub_chapter_view(state: &State) -> Element<'_, Message> {
    let font_size = state.font_size;
    let text_color = state.theme.text_color();
    let line_gap = state.font_size * state.line_spacing;
    let bg = state.theme.background();
    let mut spread = row![].spacing(PAGE_GUTTER).height(Length::Fill);
    let visible_pages = epub_visible_pages(state);
    let text_width = epub_page_size(state).width;
    let fonts = match &state.document {
        Some(OpenDocument::Epub(doc)) => Some(doc.fonts()),
        _ => None,
    };

    for (visible_index, page_index) in visible_pages.iter().enumerate() {
        let epub_page = &state.epub_pages[*page_index];
        let highlights = search_highlight_models_for_page(state, epub_page.chapter);
        let mut page = column![].width(Length::Fill);
        if let Some(title) = &epub_page.title {
            page = page.push(
                container(text(title.clone()).size(font_size * 1.5).color(text_color)).padding(
                    iced::Padding {
                        bottom: line_gap,
                        ..iced::Padding::ZERO
                    },
                ),
            );
        }
        for page_node in &epub_page.nodes {
            let before = page_node.block_before;
            let block_spacing = page_node.block_after;
            let rendered = render_content_node(
                &page_node.node,
                &state.i18n,
                font_size,
                state.theme.palette(),
                &state.epub_image_handles,
                true,
                text_width,
                Some(epub_page_size(state).height),
                Some((epub_page_size(state).height - before - block_spacing).max(1.0)),
                page_node.text_offset,
                &highlights,
                fonts,
                state.window_scale_factor,
            );
            page = page.push(container(rendered).padding(iced::Padding {
                top: before,
                bottom: block_spacing,
                ..iced::Padding::ZERO
            }));
        }
        page = page.push(iced::widget::Space::new().height(Length::Fill));
        page = page.push(
            text(format!("{}", page_index + 1))
                .size(EPUB_PAGE_NUMBER_SIZE)
                .color(iced::Color {
                    a: 0.55,
                    ..text_color
                }),
        );
        let page_content = container(page)
            .width(Length::Fill)
            .height(Length::Fill)
            .max_width(text_width);
        let content_alignment = if epub_uses_spread(state) {
            if visible_index == 0 {
                iced::Alignment::End
            } else {
                iced::Alignment::Start
            }
        } else {
            iced::Alignment::Center
        };
        spread = spread.push(
            container(page_content)
                .padding(20)
                .width(Length::FillPortion(1))
                .height(Length::Fill)
                .align_x(content_alignment)
                .style(move |_| container::Style {
                    background: Some(iced::Background::Color(bg)),
                    ..Default::default()
                }),
        );
    }
    if epub_uses_spread(state) && visible_pages.len() == 1 {
        spread = spread.push(container(iced::widget::Space::new()).width(Length::FillPortion(1)));
    }

    container(spread)
        .padding(20)
        .style(move |_theme| container::Style {
            background: Some(iced::Background::Color(bg)),
            ..Default::default()
        })
        .width(Length::Fill)
        .height(Length::Fill)
        .into()
}

#[allow(clippy::too_many_arguments)]
fn render_content_node<'a>(
    node: &ContentNode,
    i18n: &I18n,
    font_size: f32,
    palette: ReaderPalette,
    image_handles: &HashMap<String, EpubImageHandle>,
    fill_images: bool,
    available_width: f32,
    percentage_height_basis: Option<f32>,
    available_height: Option<f32>,
    text_offset: usize,
    highlights: &[SearchHighlight],
    fonts: Option<&'a EpubFontBook>,
    scale: f32,
) -> Element<'a, Message> {
    let text_color = palette.text;
    match node {
        ContentNode::Heading {
            level,
            spans,
            style,
        } => {
            let size = epub_heading_font_size(*level, style, font_size);
            let align = node_style_to_alignment(style);
            let heading = render_spans(
                spans,
                style.direction,
                size,
                palette,
                text_offset,
                highlights,
                fonts,
                scale,
                style.text_align,
                available_width,
                available_height,
            );
            container(heading).width(Length::Fill).align_x(align).into()
        }

        ContentNode::Paragraph(spans, style) => {
            let size = style
                .font_size_multiplier
                .map(|m| font_size * m)
                .unwrap_or(font_size);
            let align = node_style_to_alignment(style);
            let rendered = render_spans(
                spans,
                style.direction,
                size,
                palette,
                text_offset,
                highlights,
                fonts,
                scale,
                style.text_align,
                crate::epub::paragraph_width(available_width, font_size, style),
                available_height,
            );
            let mut c = container(rendered).width(Length::Fill).align_x(align);
            if let Some(margin) = style.margin_left_em {
                c = c.padding(iced::Padding {
                    left: margin * font_size,
                    ..iced::Padding::ZERO
                });
            }
            c.into()
        }

        ContentNode::BlockQuote { children, style } => {
            let mut col = column![];
            let mut child_offset = text_offset;
            for (child_index, child) in children.iter().enumerate() {
                col = col.push(iced::widget::Space::new().height(Length::Fixed(
                    crate::epub::epub_fragment_boundary_spacing(
                        children,
                        child_index,
                        font_size,
                        EPUB_BLOCKQUOTE_SPACING,
                        style,
                    ),
                )));
                col = col.push(render_content_node(
                    child,
                    i18n,
                    font_size,
                    palette,
                    image_handles,
                    fill_images,
                    (available_width - style.margin_left_em.unwrap_or(1.0) * font_size).max(1.0),
                    None,
                    available_height,
                    child_offset,
                    highlights,
                    fonts,
                    scale,
                ));
                child_offset += content_node_text_len(child) + 1;
            }
            col = col.push(iced::widget::Space::new().height(Length::Fixed(
                crate::epub::epub_fragment_boundary_spacing(
                    children,
                    children.len(),
                    font_size,
                    EPUB_BLOCKQUOTE_SPACING,
                    style,
                ),
            )));
            let margin = style.margin_left_em.unwrap_or(1.0) * font_size;
            container(col)
                .width(Length::Fill)
                .padding(iced::Padding {
                    left: margin,
                    ..iced::Padding::ZERO
                })
                .into()
        }

        ContentNode::Figure { children, style } => {
            let figure_width =
                crate::epub::epub_figure_content_width(style, available_width, font_size);
            let mut figure = column![];
            let mut child_offset = text_offset;
            let figure_spacing = (0..=children.len())
                .map(|boundary| {
                    crate::epub::epub_fragment_boundary_spacing(
                        children,
                        boundary,
                        font_size,
                        EPUB_BLOCKQUOTE_SPACING,
                        style,
                    )
                })
                .sum::<f32>();
            let mut figure_remaining_height = available_height
                .map(|height| (height - figure_spacing).max(1.0))
                .unwrap_or(f32::MAX);
            let figure_chars_per_line = (figure_width
                / (font_size * crate::epub::AVERAGE_CHARACTER_WIDTH).max(1.0))
            .floor()
            .max(1.0) as usize;
            let figure_lines_per_page = (figure_remaining_height / (font_size * 1.2))
                .max(1.0)
                .min(usize::MAX as f32) as usize;
            for (child_index, child) in children.iter().enumerate() {
                figure = figure.push(iced::widget::Space::new().height(Length::Fixed(
                    crate::epub::epub_fragment_boundary_spacing(
                        children,
                        child_index,
                        font_size,
                        EPUB_BLOCKQUOTE_SPACING,
                        style,
                    ),
                )));
                figure = figure.push(render_content_node(
                    child,
                    i18n,
                    font_size,
                    palette,
                    image_handles,
                    fill_images,
                    figure_width,
                    None,
                    Some(figure_remaining_height),
                    child_offset,
                    highlights,
                    fonts,
                    scale,
                ));
                let child_height = crate::epub::epub_bounded_node_height(
                    fonts,
                    child,
                    font_size,
                    figure_width,
                    figure_remaining_height,
                    figure_chars_per_line,
                    figure_lines_per_page,
                );
                figure_remaining_height = (figure_remaining_height - child_height).max(1.0);
                child_offset += content_node_text_len(child) + 1;
            }
            figure = figure.push(iced::widget::Space::new().height(Length::Fixed(
                crate::epub::epub_fragment_boundary_spacing(
                    children,
                    children.len(),
                    font_size,
                    EPUB_BLOCKQUOTE_SPACING,
                    style,
                ),
            )));
            container(container(figure).width(Length::Fixed(figure_width)))
                .width(Length::Fill)
                .padding(iced::Padding {
                    left: style.margin_left_em.unwrap_or(0.0) * font_size,
                    ..iced::Padding::ZERO
                })
                .into()
        }

        ContentNode::Table {
            caption,
            caption_style,
            row_groups,
            style,
        } => {
            let mut table = column![].spacing(EPUB_TABLE_ROW_SPACING);
            let table_width =
                crate::epub::epub_table_layout_width(row_groups, style, available_width);
            let table_content_width = crate::epub::epub_table_content_width(
                style,
                table_width,
                available_width,
                font_size,
            );
            let column_widths =
                crate::epub::epub_table_column_widths(row_groups, table_content_width);
            let table_height = available_height.unwrap_or(f32::MAX);
            let caption_height = crate::epub::epub_table_caption_height(
                fonts,
                caption,
                caption_style.as_ref(),
                font_size,
                table_content_width,
                table_height,
            );
            let caption_gap = EPUB_TABLE_ROW_SPACING
                * usize::from(!caption.is_empty() && !row_groups.is_empty()) as f32;
            let table_content_height = (table_height - caption_height - caption_gap).max(1.0);
            let table_lines_per_page = (table_height / (font_size * 1.2)).max(1.0) as usize;
            let geometry = crate::epub::epub_table_geometry_bounded(
                row_groups,
                &column_widths,
                table_lines_per_page,
                font_size,
                table_content_height,
                fonts,
            );
            let mut table_offset = text_offset;
            if !caption.is_empty() {
                let caption_style = caption_style.as_ref().unwrap_or(style);
                let caption_size = caption_style
                    .font_size_multiplier
                    .map_or(font_size, |multiplier| font_size * multiplier);
                table = table.push(render_spans(
                    caption,
                    caption_style.direction,
                    caption_size,
                    palette,
                    table_offset,
                    highlights,
                    fonts,
                    scale,
                    caption_style.text_align,
                    table_content_width,
                    available_height,
                ));
                table_offset += spans_text_len(caption) + 1;
            }
            let mut grid = iced::widget::Stack::new().push(
                iced::widget::Space::new()
                    .width(table_content_width)
                    .height(geometry.height),
            );
            for ((table_row, row_geometry), _row_index) in row_groups
                .iter()
                .flat_map(|group| &group.rows)
                .zip(&geometry.cells)
                .zip(0..)
            {
                for (cell_index, (cell, cell_geometry)) in
                    table_row.cells.iter().zip(row_geometry).enumerate()
                {
                    let mut rendered_cell = column![];
                    let cell_content_width = crate::epub::epub_table_cell_content_width(
                        cell_geometry.placement,
                        &column_widths,
                    );
                    let mut cell_remaining_height = crate::epub::epub_table_cell_content_height(
                        &cell.children,
                        font_size,
                        table_content_height,
                    );
                    let cell_chars_per_line = (cell_content_width
                        / (font_size * crate::epub::AVERAGE_CHARACTER_WIDTH).max(1.0))
                    .floor()
                    .max(1.0) as usize;
                    for (child_index, child) in cell.children.iter().enumerate() {
                        if cell.block_starts.contains(&child_index) {
                            table_offset += 1;
                        }
                        rendered_cell = rendered_cell.push(iced::widget::Space::new().height(
                            Length::Fixed(crate::epub::epub_node_boundary_spacing(
                                &cell.children,
                                child_index,
                                font_size,
                                EPUB_TABLE_CELL_SPACING,
                            )),
                        ));
                        rendered_cell = rendered_cell.push(render_content_node(
                            child,
                            i18n,
                            font_size,
                            palette,
                            image_handles,
                            fill_images,
                            cell_content_width,
                            None,
                            Some(cell_remaining_height),
                            table_offset,
                            highlights,
                            fonts,
                            scale,
                        ));
                        let child_height = crate::epub::epub_bounded_node_height(
                            fonts,
                            child,
                            font_size,
                            cell_content_width,
                            cell_remaining_height,
                            cell_chars_per_line,
                            table_lines_per_page,
                        );
                        cell_remaining_height = (cell_remaining_height - child_height).max(1.0);
                        table_offset += content_node_text_len(child);
                    }
                    rendered_cell = rendered_cell.push(iced::widget::Space::new().height(
                        Length::Fixed(crate::epub::epub_node_boundary_spacing(
                            &cell.children,
                            cell.children.len(),
                            font_size,
                            EPUB_TABLE_CELL_SPACING,
                        )),
                    ));
                    let header = cell.header;
                    let painted_cell = container(rendered_cell)
                        .width(Length::Fixed(cell_geometry.width))
                        .height(Length::Fixed(cell_geometry.height))
                        .padding(EPUB_TABLE_CELL_PADDING)
                        .clip(true)
                        .style(move |_| container::Style {
                            background: header.then_some(iced::Background::Color(
                                palette.table_header_background,
                            )),
                            border: iced::Border {
                                color: palette.table_header_border,
                                width: if header { 1.0 } else { 0.0 },
                                ..Default::default()
                            },
                            ..container::Style::default()
                        });
                    grid = grid.push(container(painted_cell).padding(iced::Padding {
                        top: cell_geometry.y,
                        left: cell_geometry.x,
                        ..iced::Padding::ZERO
                    }));
                    if cell_index + 1 < table_row.cells.len() {
                        table_offset += 1;
                    }
                }
                table_offset += 1;
            }
            table = table.push(grid);
            let margin_left = crate::epub::epub_table_margin_left(
                style,
                font_size,
                available_width,
                table_content_width,
            );
            let table = container(container(table).width(Length::Fixed(table_content_width)))
                .width(Length::Fixed(table_content_width + margin_left))
                .padding(iced::Padding {
                    left: margin_left,
                    ..iced::Padding::ZERO
                });
            scrollable(table)
                .direction(scrollable::Direction::Horizontal(
                    scrollable::Scrollbar::default(),
                ))
                .width(Length::Fill)
                .into()
        }

        ContentNode::UnorderedList(items) => {
            let mut col = column![].spacing(4);
            let mut item_offset = text_offset;
            for item_spans in items {
                col = col.push(render_spans_with_prefix(
                    "  \u{2022} ",
                    font_size * spans_font_scale(item_spans),
                    item_spans,
                    shosai_core::epub::style::TextDirection::Ltr,
                    font_size,
                    palette,
                    item_offset,
                    highlights,
                    fonts,
                    scale,
                    None,
                    available_width,
                    available_height,
                    false,
                ));
                item_offset += spans_text_len(item_spans) + 1;
            }
            col.into()
        }

        ContentNode::OrderedList { items, start } => {
            let mut col = column![].spacing(4);
            let mut item_offset = text_offset;
            for (i, item_spans) in items.iter().enumerate() {
                let num_text = format!("  {}. ", start.saturating_add(i));
                col = col.push(render_spans_with_prefix(
                    &num_text,
                    font_size * spans_font_scale(item_spans),
                    item_spans,
                    shosai_core::epub::style::TextDirection::Ltr,
                    font_size,
                    palette,
                    item_offset,
                    highlights,
                    fonts,
                    scale,
                    None,
                    available_width,
                    available_height,
                    false,
                ));
                item_offset += spans_text_len(item_spans) + 1;
            }
            col.into()
        }

        ContentNode::CodeBlock { code, language } => render_code_block(
            code,
            language.as_deref(),
            font_size,
            palette,
            text_offset,
            highlights,
        ),

        ContentNode::InlineCode(code_text) => {
            // Render as monospace span inline
            let mono_font = Font {
                family: iced::font::Family::Monospace,
                ..Font::DEFAULT
            };
            render_highlighted_text_with_font(
                code_text,
                text_offset,
                font_size * 0.9,
                palette,
                mono_font,
                highlights,
            )
        }

        ContentNode::Image { .. } => render_epub_image(
            node,
            i18n,
            font_size,
            palette,
            image_handles,
            available_width,
            percentage_height_basis,
            available_height,
            text_offset,
            highlights,
            fonts,
            scale,
        ),

        ContentNode::Math {
            content,
            style,
            link,
        } => {
            let size = font_size * style.font_size_multiplier.unwrap_or(1.0);
            if let Some(layout) = content.expression.as_ref().and_then(|expression| {
                crate::epub::math_layout::layout_math_for_bounds(
                    expression,
                    size,
                    available_width,
                    available_height.unwrap_or(f32::MAX),
                )
            }) {
                let highlight =
                    math_highlight_state(highlights, text_offset, content.fallback.chars().count());
                let math = if let Some(link) = link {
                    crate::epub::math_widget::linked_math(
                        layout,
                        palette.text,
                        math_highlight_color(palette, highlight),
                        Message::LinkClicked(link.clone()),
                    )
                } else {
                    crate::epub::math_widget::math(
                        layout,
                        palette.text,
                        math_highlight_color(palette, highlight),
                    )
                };
                return container(math)
                    .width(Length::Fill)
                    .align_x(node_style_to_alignment(style))
                    .into();
            }
            let fallback = shosai_core::epub::render::TextSpan {
                text: content.fallback.clone(),
                math: None,
                font_family: None,
                bold: false,
                italic: false,
                monospace: false,
                font_size_multiplier: 1.0,
                preserve_whitespace: false,
                link: link.clone(),
            };
            let rendered = render_spans(
                std::slice::from_ref(&fallback),
                style.direction,
                size,
                palette,
                text_offset,
                highlights,
                None,
                scale,
                style.text_align,
                available_width,
                available_height,
            );
            container(rendered)
                .width(Length::Fill)
                .align_x(node_style_to_alignment(style))
                .into()
        }

        ContentNode::HorizontalRule => text("───────────────────")
            .size(font_size)
            .color(text_color)
            .into(),
    }
}

fn math_highlight_state(
    highlights: &[SearchHighlight],
    text_offset: usize,
    text_len: usize,
) -> Option<bool> {
    let text_end = text_offset + text_len;
    highlights
        .iter()
        .filter(|highlight| highlight.start < text_end && highlight.end > text_offset)
        .map(|highlight| highlight.current)
        .max()
}

fn math_highlight_color(palette: ReaderPalette, highlight: Option<bool>) -> Option<iced::Color> {
    highlight.map(|current| {
        if current {
            palette.current_search_highlight
        } else {
            palette.search_highlight
        }
    })
}

fn epub_heading_font_size(
    level: u8,
    style: &shosai_core::epub::render::NodeStyle,
    font_size: f32,
) -> f32 {
    let base_size = match level {
        1 => font_size * 2.0,
        2 => font_size * 1.6,
        3 => font_size * 1.3,
        4 => font_size * 1.1,
        _ => font_size,
    };
    style
        .font_size_multiplier
        .map_or(base_size, |multiplier| base_size * multiplier)
}

/// Render a cached EPUB image, falling back to alt text.
#[allow(clippy::too_many_arguments)]
fn render_epub_image<'a>(
    node: &ContentNode,
    i18n: &I18n,
    font_size: f32,
    palette: ReaderPalette,
    image_handles: &HashMap<String, EpubImageHandle>,
    available_width: f32,
    percentage_height_basis: Option<f32>,
    available_height: Option<f32>,
    text_offset: usize,
    highlights: &[SearchHighlight],
    fonts: Option<&'a EpubFontBook>,
    scale: f32,
) -> Element<'a, Message> {
    let ContentNode::Image {
        src,
        alt,
        style: image_style,
        caption,
        caption_style,
        ..
    } = node
    else {
        unreachable!("image renderer requires an image node");
    };
    let margin_left = crate::epub::epub_image_margin_left(image_style, font_size, available_width);
    let text_color = palette.text;
    if let Some(handle) = image_handles.get(src) {
        let layout = crate::epub::epub_image_layout(
            node,
            font_size,
            available_width,
            percentage_height_basis,
            available_height,
            fonts,
        )
        .expect("image node has image layout");
        let rendered: Element<'a, Message> = match handle {
            EpubImageHandle::Raster(handle) => image(handle)
                .content_fit(iced::ContentFit::Fill)
                .width(Length::Fixed(layout.width))
                .height(Length::Fixed(layout.height))
                .into(),
            EpubImageHandle::Svg(handle) => svg(handle.clone())
                .content_fit(iced::ContentFit::Fill)
                .width(Length::Fixed(layout.width))
                .height(Length::Fixed(layout.height))
                .into(),
        };
        let alt_highlight = image_alt_highlight(alt, text_offset, highlights);
        let image_container = container(
            container(rendered)
                .width(Length::Fixed(layout.width))
                .height(Length::Fixed(layout.height))
                .style(move |_| image_highlight_style(palette, alt_highlight)),
        )
        .width(Length::Fill)
        .center_x(Length::Fill);
        let mut figure = column![image_container].width(Length::Fill);
        if !caption.is_empty() {
            let style = caption_style.as_ref().cloned().unwrap_or_default();
            let caption_size = font_size * style.font_size_multiplier.unwrap_or(1.0);
            figure = figure
                .push(iced::widget::Space::new().height(Length::Fixed(layout.caption_gap)))
                .push(
                    container(
                        container(render_spans(
                            caption,
                            style.direction,
                            caption_size,
                            palette,
                            text_offset + alt.chars().count() + 1,
                            highlights,
                            fonts,
                            scale,
                            style.text_align,
                            layout.width,
                            Some(layout.caption_height.max(1.0)),
                        ))
                        .width(Length::Fixed(layout.width))
                        .height(Length::Fixed(layout.caption_height)),
                    )
                    .width(Length::Fill)
                    .center_x(Length::Fill),
                );
        }
        return container(figure)
            .width(Length::Fill)
            .padding(iced::Padding {
                left: margin_left,
                ..iced::Padding::ZERO
            })
            .into();
    }

    // Fallback: show alt text placeholder.
    let mut spans: Vec<iced::widget::text::Span<'_, String>> = vec![
        span(format!("[{}: ", i18n.text("image")))
            .size(font_size)
            .color(text_color),
    ];
    spans.extend(
        highlighted_fragments(alt, text_offset, highlights)
            .into_iter()
            .map(|(fragment, highlight)| {
                apply_search_highlight(
                    span(fragment).size(font_size).color(text_color),
                    highlight,
                    palette,
                )
            }),
    );
    spans.push(span("]".to_string()).size(font_size).color(text_color));
    let layout = crate::epub::epub_image_layout(
        node,
        font_size,
        available_width,
        percentage_height_basis,
        available_height,
        fonts,
    )
    .expect("image node has fallback layout");
    let mut fallback = column![
        container(rich_text(spans))
            .width(Length::Fixed(layout.width))
            .height(Length::Fixed(layout.height))
            .clip(true)
    ]
    .width(Length::Fill);
    if !caption.is_empty() {
        let style = caption_style.as_ref().cloned().unwrap_or_default();
        fallback = fallback
            .push(iced::widget::Space::new().height(Length::Fixed(layout.caption_gap)))
            .push(
                container(
                    container(render_spans(
                        caption,
                        style.direction,
                        font_size * style.font_size_multiplier.unwrap_or(1.0),
                        palette,
                        text_offset + alt.chars().count() + 1,
                        highlights,
                        fonts,
                        scale,
                        style.text_align,
                        layout.width,
                        Some(layout.caption_height.max(1.0)),
                    ))
                    .width(Length::Fixed(layout.width))
                    .height(Length::Fixed(layout.caption_height)),
                )
                .width(Length::Fill)
                .center_x(Length::Fill),
            );
    }
    container(fallback)
        .width(Length::Fill)
        .padding(iced::Padding {
            left: margin_left,
            ..iced::Padding::ZERO
        })
        .into()
}

fn image_alt_highlight(
    alt: &str,
    text_offset: usize,
    highlights: &[SearchHighlight],
) -> Option<bool> {
    highlighted_fragments(alt, text_offset, highlights)
        .into_iter()
        .filter_map(|(_, highlight)| highlight)
        .max()
}

fn image_highlight_style(palette: ReaderPalette, highlight: Option<bool>) -> container::Style {
    let Some(current) = highlight else {
        return container::Style::default();
    };
    let color = native_epub_highlight_color(palette, current);
    container::Style {
        background: Some(iced::Background::Color(iced::Color::from_rgba8(
            color[0],
            color[1],
            color[2],
            color[3] as f32 / 255.0,
        ))),
        border: iced::Border {
            color: palette.text,
            width: 2.0,
            ..Default::default()
        },
        ..Default::default()
    }
}

/// Render a code block with optional syntax highlighting.
fn render_code_block<'a>(
    code: &str,
    language: Option<&str>,
    font_size: f32,
    palette: ReaderPalette,
    text_offset: usize,
    highlights: &[SearchHighlight],
) -> Element<'a, Message> {
    use shosai_core::highlight;

    let text_color = palette.text;
    let mono_font = Font {
        family: iced::font::Family::Monospace,
        ..Font::DEFAULT
    };
    let code_size = font_size * 0.85;

    // Try syntax highlighting.
    let theme_name = highlight::syntect_theme_for_reader(
        text_color.r > 0.5, // dark theme = light text
    );

    if let Some(highlighted_lines) = highlight::highlight_code(code, language, theme_name) {
        let bg_color = highlight::theme_background(theme_name)
            .map(|(r, g, b)| iced::Color::from_rgb8(r, g, b))
            .unwrap_or(iced::Color::from_rgb(0.15, 0.15, 0.18));

        let mut lines_col = column![].spacing(0);
        let mut code_offset = text_offset;

        for line_spans in &highlighted_lines {
            let rich_spans: Vec<iced::widget::text::Span<'_, Message>> =
                highlighted_code_line(line_spans, &mut code_offset, highlights)
                    .into_iter()
                    .map(|fragment| {
                        let (r, g, b) = fragment.color;
                        let mut font = mono_font;
                        if fragment.bold {
                            font.weight = iced::font::Weight::Bold;
                        }
                        if fragment.italic {
                            font.style = iced::font::Style::Italic;
                        }
                        apply_search_highlight(
                            span(fragment.text)
                                .size(code_size)
                                .font(font)
                                .color(iced::Color::from_rgb8(r, g, b)),
                            fragment.search_highlight,
                            palette,
                        )
                    })
                    .collect();

            lines_col = lines_col.push(rich_text(rich_spans));
        }

        return container(lines_col)
            .padding(12)
            .width(Length::Fill)
            .style(move |_theme| container::Style {
                background: Some(iced::Background::Color(bg_color)),
                border: iced::Border {
                    radius: 4.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            })
            .into();
    }

    // Fallback: plain monospace text.
    container(render_highlighted_text_with_font(
        code,
        text_offset,
        code_size,
        palette,
        mono_font,
        highlights,
    ))
    .padding(12)
    .width(Length::Fill)
    .style(move |_theme| container::Style {
        background: Some(iced::Background::Color(iced::Color::from_rgb(
            0.15, 0.15, 0.18,
        ))),
        border: iced::Border {
            radius: 4.0.into(),
            ..Default::default()
        },
        ..Default::default()
    })
    .into()
}

#[derive(Debug, PartialEq)]
struct HighlightedCodeFragment {
    pub(super) text: String,
    pub(super) color: (u8, u8, u8),
    bold: bool,
    italic: bool,
    pub(super) search_highlight: Option<bool>,
}

fn highlighted_code_line(
    line: &[shosai_core::highlight::HighlightSpan],
    code_offset: &mut usize,
    highlights: &[SearchHighlight],
) -> Vec<HighlightedCodeFragment> {
    let mut fragments = Vec::new();
    for syntax_span in line {
        fragments.extend(
            highlighted_fragments(&syntax_span.text, *code_offset, highlights)
                .into_iter()
                .map(|(text, search_highlight)| HighlightedCodeFragment {
                    text,
                    color: syntax_span.color,
                    bold: syntax_span.bold,
                    italic: syntax_span.italic,
                    search_highlight,
                }),
        );
        *code_offset += syntax_span.text.chars().count();
    }
    fragments
}

fn node_style_to_alignment(
    style: &shosai_core::epub::render::NodeStyle,
) -> iced::alignment::Horizontal {
    match style.text_align {
        Some(shosai_core::epub::style::TextAlignment::Center) => {
            iced::alignment::Horizontal::Center
        }
        Some(shosai_core::epub::style::TextAlignment::Right) => iced::alignment::Horizontal::Right,
        _ => iced::alignment::Horizontal::Left,
    }
}

#[allow(clippy::too_many_arguments)]
fn render_spans<'a>(
    spans: &[shosai_core::epub::render::TextSpan],
    direction: shosai_core::epub::style::TextDirection,
    font_size: f32,
    palette: ReaderPalette,
    text_offset: usize,
    highlights: &[SearchHighlight],
    fonts: Option<&'a EpubFontBook>,
    scale: f32,
    alignment: Option<shosai_core::epub::style::TextAlignment>,
    available_width: f32,
    available_height: Option<f32>,
) -> Element<'a, Message> {
    render_spans_with_prefix(
        "",
        font_size,
        spans,
        direction,
        font_size,
        palette,
        text_offset,
        highlights,
        fonts,
        scale,
        alignment,
        available_width,
        available_height,
        false,
    )
}

#[allow(clippy::too_many_arguments)]
fn render_spans_with_prefix<'a>(
    prefix: &str,
    prefix_font_size: f32,
    spans: &[shosai_core::epub::render::TextSpan],
    direction: shosai_core::epub::style::TextDirection,
    font_size: f32,
    palette: ReaderPalette,
    text_offset: usize,
    highlights: &[SearchHighlight],
    fonts: Option<&'a EpubFontBook>,
    scale: f32,
    alignment: Option<shosai_core::epub::style::TextAlignment>,
    available_width: f32,
    available_height: Option<f32>,
    shrink_native: bool,
) -> Element<'a, Message> {
    if direction == shosai_core::epub::style::TextDirection::Ltr
        && alignment != Some(shosai_core::epub::style::TextAlignment::Justify)
        && spans.iter().any(|span| span.math.is_some())
    {
        let mut inline_spans = Vec::with_capacity(spans.len() + usize::from(!prefix.is_empty()));
        if !prefix.is_empty() {
            inline_spans.push(shosai_core::epub::render::TextSpan {
                text: prefix.to_owned(),
                math: None,
                font_family: None,
                bold: false,
                italic: false,
                monospace: false,
                font_size_multiplier: prefix_font_size / font_size,
                preserve_whitespace: false,
                link: None,
            });
        }
        inline_spans.extend_from_slice(spans);
        return render_inline_math_spans(
            &inline_spans,
            usize::from(!prefix.is_empty()),
            direction,
            font_size,
            palette,
            text_offset,
            highlights,
            fonts,
            scale,
            alignment,
            available_width,
            available_height,
        );
    }
    let text_color = palette.text;
    if let Some(fonts) = fonts.filter(|fonts| crate::epub::uses_native_fonts(fonts, spans)) {
        let prefix_scalars = prefix.chars().count();
        let mut runs = Vec::with_capacity(spans.len() + usize::from(!prefix.is_empty()));
        if !prefix.is_empty() {
            runs.push(EpubTextRun {
                text: prefix.to_owned(),
                family: None,
                monospace: false,
                font_size: prefix_font_size,
                bold: false,
                italic: false,
                foreground: color_rgba(text_color),
                link: None,
            });
        }
        runs.extend(
            spans
                .iter()
                .map(|span| native_epub_run(span, font_size, palette)),
        );
        let text_len = spans_text_len(spans);
        let native_highlights = highlights
            .iter()
            .filter_map(|highlight| {
                let start = highlight.start.max(text_offset);
                let end = highlight.end.min(text_offset + text_len);
                (start < end).then(|| EpubTextHighlight {
                    scalars: prefix_scalars + start - text_offset
                        ..prefix_scalars + end - text_offset,
                    color: native_epub_highlight_color(palette, highlight.current),
                })
            })
            .collect();
        let line_height = runs
            .iter()
            .map(|run| run.font_size)
            .fold(font_size, f32::max)
            * crate::epub::TEXT_LINE_HEIGHT;
        let request = EpubTextRequest {
            runs,
            max_width: 1.0,
            line_height,
            scale: scale.max(0.1),
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
            highlights: native_highlights,
        };
        return if shrink_native {
            crate::epub::native_text::native_text_shrink(fonts, request, epub_link_clicked)
        } else {
            crate::epub::native_text::native_text(fonts, request, epub_link_clicked)
        };
    }

    let mut rich_spans: Vec<iced::widget::text::Span<'a, String>> = Vec::new();
    let (isolate, pop_isolate) = text_direction_controls(direction);
    rich_spans.push(span(isolate.to_string()).size(font_size));
    if !prefix.is_empty() {
        rich_spans.push(
            span(prefix.to_string())
                .size(prefix_font_size)
                .color(text_color),
        );
    }

    let mut span_offset = text_offset;
    for text_span in spans {
        for (fragment, highlight) in highlighted_fragments(&text_span.text, span_offset, highlights)
        {
            rich_spans.push(styled_epub_span(
                text_span, fragment, font_size, palette, highlight,
            ));
        }
        span_offset += text_span.text.chars().count();
    }
    rich_spans.push(span(pop_isolate.to_string()).size(font_size));

    container(
        rich_text(rich_spans)
            .wrapping(epub_fallback_wrapping())
            .on_link_click(epub_link_clicked),
    )
    .width(Length::Fixed(available_width.max(1.0)))
    .into()
}

fn color_rgba(color: iced::Color) -> [u8; 4] {
    [
        (color.r * 255.0).round() as u8,
        (color.g * 255.0).round() as u8,
        (color.b * 255.0).round() as u8,
        (color.a * 255.0).round() as u8,
    ]
}

fn epub_fallback_wrapping() -> iced::widget::text::Wrapping {
    iced::widget::text::Wrapping::WordOrGlyph
}

#[allow(clippy::too_many_arguments)]
fn render_inline_math_spans<'a>(
    spans: &[shosai_core::epub::render::TextSpan],
    source_prefix_spans: usize,
    direction: shosai_core::epub::style::TextDirection,
    font_size: f32,
    palette: ReaderPalette,
    text_offset: usize,
    highlights: &[SearchHighlight],
    fonts: Option<&'a EpubFontBook>,
    scale: f32,
    alignment: Option<shosai_core::epub::style::TextAlignment>,
    available_width: f32,
    available_height: Option<f32>,
) -> Element<'a, Message> {
    if !crate::epub::inline_math_flow_is_admitted(spans) {
        let prefix = spans[..source_prefix_spans]
            .iter()
            .map(|span| span.text.as_str())
            .collect::<String>();
        let mut fallback = spans[source_prefix_spans..].to_vec();
        for span in &mut fallback {
            span.math = None;
        }
        return render_spans_with_prefix(
            &prefix,
            font_size,
            &fallback,
            direction,
            font_size,
            palette,
            text_offset,
            highlights,
            fonts,
            scale,
            alignment,
            available_width,
            available_height,
            false,
        );
    }
    let mut flow = row![]
        .spacing(0)
        .align_y(iced::Alignment::End)
        .width(Length::Fill);
    let mut source_offset = text_offset;

    for (span_index, source) in spans.iter().enumerate() {
        let is_prefix = span_index < source_prefix_spans;
        if let Some(content) = &source.math
            && let Some(layout) = crate::epub::layout_inline_math_span_for_context(
                source,
                font_size,
                available_width,
                available_height.unwrap_or(f32::MAX),
                direction,
                alignment,
            )
        {
            let highlight =
                math_highlight_state(highlights, source_offset, content.fallback.chars().count());
            let math = if let Some(link) = &source.link {
                crate::epub::math_widget::linked_math(
                    layout,
                    palette.text,
                    math_highlight_color(palette, highlight),
                    Message::LinkClicked(link.clone()),
                )
            } else {
                crate::epub::math_widget::math(
                    layout,
                    palette.text,
                    math_highlight_color(palette, highlight),
                )
            };
            flow = flow.push(container(math));
            if !is_prefix {
                source_offset += source.text.chars().count();
            }
            continue;
        }

        for piece in inline_flow_text_pieces(&source.text) {
            if piece.is_empty() {
                continue;
            }
            let mut text_span = source.clone();
            text_span.text = piece.to_owned();
            text_span.math = None;
            flow = flow.push(render_spans_with_prefix(
                "",
                font_size,
                std::slice::from_ref(&text_span),
                direction,
                font_size,
                palette,
                source_offset,
                if is_prefix { &[] } else { highlights },
                fonts,
                scale,
                None,
                available_width,
                available_height,
                true,
            ));
            if !is_prefix {
                source_offset += piece.chars().count();
            }
        }
    }

    flow.wrap()
        .vertical_spacing(font_size * crate::epub::INLINE_MATH_WRAP_SPACING)
        .align_x(match alignment {
            Some(shosai_core::epub::style::TextAlignment::Center) => {
                iced::alignment::Horizontal::Center
            }
            Some(shosai_core::epub::style::TextAlignment::Right) => {
                iced::alignment::Horizontal::Right
            }
            _ => iced::alignment::Horizontal::Left,
        })
        .into()
}

fn inline_flow_text_pieces(text: &str) -> Vec<&str> {
    text.split_inclusive(char::is_whitespace).collect()
}

fn native_epub_run(
    span: &shosai_core::epub::render::TextSpan,
    font_size: f32,
    palette: ReaderPalette,
) -> EpubTextRun {
    EpubTextRun {
        text: span.text.clone(),
        family: span.font_family.as_deref().map(str::to_owned),
        monospace: span.monospace,
        font_size: epub_span_size(font_size, span),
        bold: span.bold,
        italic: span.italic,
        foreground: color_rgba(if span.link.is_some() {
            palette.link
        } else {
            palette.text
        }),
        link: span.link.clone(),
    }
}

fn native_epub_highlight_color(palette: ReaderPalette, current: bool) -> [u8; 4] {
    color_rgba(if current {
        palette.current_search_highlight
    } else {
        palette.search_highlight
    })
}

fn epub_link_clicked(href: String) -> Message {
    Message::LinkClicked(href)
}

fn text_direction_controls(direction: shosai_core::epub::style::TextDirection) -> (char, char) {
    let isolate = match direction {
        shosai_core::epub::style::TextDirection::Ltr => '\u{2066}',
        shosai_core::epub::style::TextDirection::Rtl => '\u{2067}',
    };
    (isolate, '\u{2069}')
}

fn styled_epub_span<'a>(
    text_span: &shosai_core::epub::render::TextSpan,
    fragment: String,
    font_size: f32,
    palette: ReaderPalette,
    highlight: Option<bool>,
) -> iced::widget::text::Span<'a, String> {
    let is_link = text_span.link.is_some();
    let font = epub_span_font(text_span);
    let color = if is_link { palette.link } else { palette.text };
    let mut rendered = span(fragment)
        .size(epub_span_size(font_size, text_span))
        .font(font)
        .color(color);
    if is_link {
        rendered = rendered.underline(true);
    }
    if let Some(href) = &text_span.link {
        rendered = rendered.link(href.clone());
    }
    apply_search_highlight(rendered, highlight, palette)
}

fn epub_span_font(text_span: &shosai_core::epub::render::TextSpan) -> Font {
    Font {
        family: if text_span.monospace {
            iced::font::Family::Monospace
        } else {
            iced::font::Family::default()
        },
        weight: if text_span.bold {
            iced::font::Weight::Bold
        } else {
            iced::font::Weight::Normal
        },
        style: if text_span.italic {
            iced::font::Style::Italic
        } else {
            iced::font::Style::Normal
        },
        ..Font::DEFAULT
    }
}

fn epub_span_size(font_size: f32, text_span: &shosai_core::epub::render::TextSpan) -> f32 {
    font_size * text_span.font_size_multiplier
}

fn render_highlighted_text_with_font<'a>(
    value: &str,
    text_offset: usize,
    font_size: f32,
    palette: ReaderPalette,
    font: Font,
    highlights: &[SearchHighlight],
) -> Element<'a, Message> {
    let text_color = palette.text;
    let spans = highlighted_fragments(value, text_offset, highlights)
        .into_iter()
        .map(|(fragment, highlight)| {
            apply_search_highlight(
                span(fragment).size(font_size).font(font).color(text_color),
                highlight,
                palette,
            )
        })
        .collect::<Vec<iced::widget::text::Span<'a, String>>>();
    rich_text(spans).into()
}

fn apply_search_highlight<'a, Link>(
    text_span: iced::widget::text::Span<'a, Link>,
    highlight: Option<bool>,
    palette: ReaderPalette,
) -> iced::widget::text::Span<'a, Link> {
    match highlight {
        Some(true) => text_span.background(palette.current_search_highlight),
        Some(false) => text_span.background(palette.search_highlight),
        None => text_span,
    }
}

fn highlighted_fragments(
    value: &str,
    text_offset: usize,
    highlights: &[SearchHighlight],
) -> Vec<(String, Option<bool>)> {
    let characters = value.chars().collect::<Vec<_>>();
    let text_end = text_offset + characters.len();
    let mut boundaries = vec![text_offset, text_end];

    for highlight in highlights {
        if highlight.start < text_end && highlight.end > text_offset {
            boundaries.push(highlight.start.max(text_offset));
            boundaries.push(highlight.end.min(text_end));
        }
    }
    boundaries.sort_unstable();
    boundaries.dedup();

    boundaries
        .windows(2)
        .filter(|range| range[0] < range[1])
        .map(|range| {
            let start = range[0];
            let end = range[1];
            let highlight = highlights
                .iter()
                .find(|highlight| highlight.start <= start && highlight.end >= end)
                .map(|highlight| highlight.current);
            (
                characters[start - text_offset..end - text_offset]
                    .iter()
                    .collect(),
                highlight,
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::i18n::LanguagePreference;
    use crate::theme::ReaderTheme;
    use iced::advanced::widget::{Id as WidgetId, Operation};
    use iced::{Rectangle, Size, Vector};

    #[derive(Default)]
    struct RecordedWidgetIds {
        containers: Vec<WidgetId>,
        scrollables: Vec<WidgetId>,
        container_bounds: Vec<Rectangle>,
    }

    impl Operation for RecordedWidgetIds {
        fn traverse(&mut self, operate: &mut dyn FnMut(&mut dyn Operation)) {
            operate(self);
        }

        fn container(&mut self, id: Option<&WidgetId>, bounds: Rectangle) {
            self.containers.extend(id.cloned());
            self.container_bounds.push(bounds);
        }

        fn scrollable(
            &mut self,
            id: Option<&WidgetId>,
            _bounds: Rectangle,
            _content_bounds: Rectangle,
            _translation: Vector,
            _state: &mut dyn iced::advanced::widget::operation::Scrollable,
        ) {
            self.scrollables.extend(id.cloned());
        }
    }

    #[test]
    fn continuous_epub_view_exposes_location_operation_ids() {
        let document = Arc::new(
            EpubDoc::from_bytes(
                include_bytes!("../../../shosai-core/tests/fixtures/sample.epub").to_vec(),
            )
            .expect("fixture should be a valid EPUB"),
        );
        let (mut state, _) = super::super::boot();
        state.document = Some(OpenDocument::Epub(Arc::clone(&document)));
        state.window_size = Size::new(700.0, 800.0);
        let tab_id = 41;
        let activation = 7;
        let element = continuous_epub_content_view(&state, document.as_ref(), tab_id, activation);
        let mut renderer = iced::Renderer::Secondary(iced_tiny_skia::Renderer::new(
            Font::DEFAULT,
            iced::Pixels(16.0),
        ));
        let mut interface = iced_runtime::UserInterface::build(
            element,
            state.window_size,
            iced_runtime::user_interface::Cache::new(),
            &mut renderer,
        );
        let mut ids = RecordedWidgetIds::default();

        interface.operate(&renderer, &mut ids);

        assert!(
            ids.scrollables
                .contains(&continuous_scroll_id(tab_id, activation))
        );
        for (chapter, presentation) in document.presentation().chapters().iter().enumerate() {
            assert!(
                ids.containers
                    .contains(&continuous_item_id(tab_id, activation, chapter)),
                "missing chapter container ID for chapter {chapter}"
            );
            for node in 0..presentation.nodes().len() {
                assert!(
                    ids.containers
                        .contains(&continuous_epub_node_id(tab_id, activation, chapter, node)),
                    "missing node container ID for chapter {chapter}, node {node}"
                );
            }
            if document
                .chapter(chapter)
                .and_then(|chapter| chapter.title.as_ref())
                .is_some_and(|title| !content_starts_with_heading(presentation.nodes(), title))
            {
                assert!(
                    ids.containers
                        .contains(&continuous_epub_title_id(tab_id, activation, chapter)),
                    "missing title container ID for chapter {chapter}"
                );
            }
        }
    }

    #[test]
    fn continuous_epub_width_tracks_the_actual_reader_surface() {
        assert_eq!(continuous_epub_content_width(900.0, false), 760.0);
        assert_eq!(continuous_epub_content_width(900.0, true), 560.0);
    }

    #[test]
    fn rebuilding_the_view_reuses_epub_image_handles() {
        let mut image_bytes = Vec::new();
        ::image::DynamicImage::ImageRgba8(::image::RgbaImage::from_pixel(
            2,
            3,
            ::image::Rgba([1, 2, 3, 255]),
        ))
        .write_to(
            &mut std::io::Cursor::new(&mut image_bytes),
            ::image::ImageFormat::Png,
        )
        .unwrap();
        let resources = HashMap::from([("image.png".to_string(), image_bytes)]);
        let nodes = vec![ContentNode::Image {
            src: "image.png".to_string(),
            alt: String::new(),
            style: Default::default(),
            caption: Vec::new(),
            caption_style: None,
            intrinsic_size: None,
            kind: None,
        }];
        let mut handles = HashMap::new();

        cache_epub_image_handles(&mut handles, &nodes, &|path| {
            resources.get(path).map(Vec::as_slice)
        });
        let first_id = handles.get("image.png").unwrap().raster_id();
        drop(render_content_node(
            &nodes[0],
            &I18n::new(LanguagePreference::English),
            16.0,
            ReaderTheme::Light.palette(),
            &handles,
            false,
            600.0,
            None,
            None,
            0,
            &[],
            None,
            1.0,
        ));
        cache_epub_image_handles(&mut handles, &nodes, &|path| {
            resources.get(path).map(Vec::as_slice)
        });
        drop(render_content_node(
            &nodes[0],
            &I18n::new(LanguagePreference::English),
            16.0,
            ReaderTheme::Light.palette(),
            &handles,
            false,
            600.0,
            None,
            None,
            0,
            &[],
            None,
            1.0,
        ));

        assert_eq!(handles.get("image.png").unwrap().raster_id(), first_id);
    }

    #[test]
    fn admitted_svg_figure_is_cached_with_caption_geometry() {
        let nodes = vec![ContentNode::Image {
            src: "figure.svg".into(),
            alt: "diagram".into(),
            style: Default::default(),
            caption: vec![shosai_core::epub::render::TextSpan {
                text: "Caption".into(),
                math: None,
                font_family: None,
                bold: false,
                italic: false,
                monospace: false,
                font_size_multiplier: 1.0,
                preserve_whitespace: false,
                link: None,
            }],
            caption_style: Some(Default::default()),
            intrinsic_size: Some(shosai_core::epub::render::ImageSize {
                width: 200,
                height: 100,
            }),
            kind: Some(shosai_core::epub::render::ImageKind::Svg),
        }];
        let bytes = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100"><rect width="200" height="100"/></svg>"#;
        let mut handles = HashMap::new();
        cache_epub_image_handles(&mut handles, &nodes, &|path| {
            (path == "figure.svg").then_some(bytes.as_slice())
        });
        assert!(matches!(
            handles.get("figure.svg"),
            Some(EpubImageHandle::Svg(_))
        ));
        let layout =
            crate::epub::epub_image_layout(&nodes[0], 16.0, 400.0, Some(300.0), Some(300.0), None)
                .unwrap();
        assert_eq!((layout.width, layout.height), (200.0, 100.0));
        assert!(layout.caption_height > 0.0);
    }

    #[test]
    fn table_cell_images_are_loaded_into_the_book_local_cache() {
        use shosai_core::epub::render::{TableCell, TableRow, TableRowGroup, TableRowGroupKind};

        let mut image_bytes = Vec::new();
        ::image::DynamicImage::ImageRgba8(::image::RgbaImage::from_pixel(
            2,
            3,
            ::image::Rgba([1, 2, 3, 255]),
        ))
        .write_to(
            &mut std::io::Cursor::new(&mut image_bytes),
            ::image::ImageFormat::Png,
        )
        .unwrap();
        let resources = HashMap::from([("table.png".to_string(), image_bytes)]);
        let nodes = vec![ContentNode::Table {
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
                        children: vec![ContentNode::Image {
                            src: "table.png".to_string(),
                            alt: "diagram".to_string(),
                            style: Default::default(),
                            caption: Vec::new(),
                            caption_style: None,
                            intrinsic_size: None,
                            kind: None,
                        }],
                        block_starts: Vec::new(),
                        style: Default::default(),
                    }],
                }],
            }],
            style: Default::default(),
        }];
        let mut handles = HashMap::new();

        cache_epub_image_handles(&mut handles, &nodes, &|path| {
            resources.get(path).map(Vec::as_slice)
        });

        assert!(handles.contains_key("table.png"));
    }

    #[test]
    fn highlighted_native_math_keeps_geometry_and_uses_theme_background() {
        let highlights = [SearchHighlight {
            start: 12,
            end: 13,
            current: true,
        }];
        let expression = shosai_core::epub::MathExpression::Fraction(
            Box::new(shosai_core::epub::MathExpression::Token("a".into())),
            Box::new(shosai_core::epub::MathExpression::Token("b".into())),
        );
        let before =
            crate::epub::math_layout::layout_math_for_bounds(&expression, 20.0, 600.0, 700.0)
                .unwrap();

        assert_eq!(math_highlight_state(&highlights, 10, 7), Some(true));
        assert_eq!(
            math_highlight_color(ReaderTheme::Sepia.palette(), Some(true)),
            Some(ReaderTheme::Sepia.palette().current_search_highlight)
        );
        assert_eq!(
            crate::epub::math_layout::layout_math_for_bounds(&expression, 20.0, 600.0, 700.0,),
            Some(before),
            "highlighting must not replace native geometry with differently sized fallback text"
        );
    }

    #[test]
    fn inline_math_flow_keeps_geometry_highlight_and_link_dispatch() {
        use shosai_core::epub::render::TextSpan;
        use shosai_core::epub::{MathContent, MathDisplay, MathExpression};

        let href = "chapter.xhtml#proof";
        let math = TextSpan {
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
            link: Some(href.into()),
        };
        let highlights = [SearchHighlight {
            start: 8,
            end: 15,
            current: true,
        }];
        let geometry = crate::epub::layout_inline_math_span(&math, 18.0, 300.0, 200.0)
            .expect("supported inline math must retain native geometry");

        assert!(geometry.height > 18.0);
        assert_eq!(math_highlight_state(&highlights, 7, 7), Some(true));
        assert!(matches!(
            epub_link_clicked(math.link.clone().unwrap()),
            Message::LinkClicked(link) if link == href
        ));
        drop(render_inline_math_spans(
            std::slice::from_ref(&math),
            0,
            shosai_core::epub::style::TextDirection::Ltr,
            18.0,
            ReaderTheme::Sepia.palette(),
            7,
            &highlights,
            None,
            1.0,
            None,
            300.0,
            Some(200.0),
        ));
    }

    #[test]
    fn mixed_embedded_font_math_flow_has_a_bounded_widget_count() {
        use iced::advanced::widget::Tree;
        use shosai_core::epub::render::TextSpan;
        use shosai_core::epub::{MathContent, MathDisplay, MathExpression};

        let epub = shosai_core::epub::EpubDoc::from_bytes(
            include_bytes!("../../../shosai-core/tests/fixtures/epub-conformance/fonts.epub")
                .to_vec(),
        )
        .expect("font fixture should be valid");
        let prose = |text: String| TextSpan {
            text,
            math: None,
            font_family: Some("FixtureTtf".into()),
            bold: false,
            italic: false,
            monospace: false,
            font_size_multiplier: 1.0,
            preserve_whitespace: false,
            link: None,
        };
        let math = TextSpan {
            text: "(a)/(b)".into(),
            math: Some(MathContent {
                display: MathDisplay::Inline,
                expression: Some(MathExpression::Fraction(
                    Box::new(MathExpression::Token("a".into())),
                    Box::new(MathExpression::Token("b".into())),
                )),
                fallback: "(a)/(b)".into(),
            }),
            ..prose(String::new())
        };
        let spans = vec![
            prose("before ".repeat(120)),
            math,
            prose(" after".repeat(120)),
        ];
        let element = render_inline_math_spans(
            &spans,
            0,
            shosai_core::epub::style::TextDirection::Ltr,
            18.0,
            ReaderTheme::Light.palette(),
            0,
            &[],
            Some(epub.fonts()),
            1.0,
            None,
            360.0,
            Some(500.0),
        );
        let tree = Tree::new(element.as_widget());

        assert_eq!(
            tree.children.len(),
            242,
            "ordinary mixed-flow words must remain independent shrink-width wrap items"
        );
        assert_eq!(
            spans
                .iter()
                .map(|span| span.text.as_str())
                .collect::<String>(),
            format!("{}(a)/(b){}", "before ".repeat(120), " after".repeat(120))
        );

        let oversized = vec![prose("bounded ".repeat(300)), spans[1].clone()];
        let element = render_inline_math_spans(
            &oversized,
            0,
            shosai_core::epub::style::TextDirection::Ltr,
            18.0,
            ReaderTheme::Light.palette(),
            0,
            &[],
            Some(epub.fonts()),
            1.0,
            None,
            360.0,
            Some(500.0),
        );
        let tree = Tree::new(element.as_widget());
        assert!(
            tree.children.len() <= 1,
            "flows above the explicit item budget must use one readable fallback widget"
        );
    }

    #[test]
    fn pathological_fallback_wraps_at_glyphs_in_narrow_containers() {
        assert_eq!(
            epub_fallback_wrapping(),
            iced::widget::text::Wrapping::WordOrGlyph,
            "unbroken MathML fallback must wrap instead of painting through table cells or page edges"
        );
    }

    #[test]
    fn rich_and_native_epub_links_use_shared_palette_highlights_and_dispatch() {
        use shosai_core::epub::render::TextSpan;

        let href = "chapter.xhtml#note";
        let linked = TextSpan {
            text: "note".into(),
            math: None,
            font_family: None,
            bold: false,
            italic: false,
            monospace: false,
            font_size_multiplier: 1.0,
            preserve_whitespace: false,
            link: Some(href.into()),
        };
        let palette = ReaderTheme::Dark.palette();

        let rich = styled_epub_span(&linked, linked.text.clone(), 16.0, palette, Some(true));
        assert_eq!(rich.link.as_deref(), Some(href));
        assert_eq!(rich.color, Some(palette.link));
        assert_eq!(
            rich.highlight
                .and_then(|highlight| match highlight.background {
                    iced::Background::Color(color) => Some(color),
                    _ => None,
                }),
            Some(palette.current_search_highlight)
        );

        let native = native_epub_run(&linked, 16.0, palette);
        assert_eq!(native.link.as_deref(), Some(href));
        assert_eq!(native.foreground, color_rgba(palette.link));
        assert_eq!(
            native_epub_highlight_color(palette, true),
            color_rgba(palette.current_search_highlight)
        );

        assert!(matches!(
            epub_link_clicked(href.into()),
            Message::LinkClicked(link) if link == href
        ));
    }

    #[test]
    fn semantic_table_nested_links_and_images_reach_shared_app_paths() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../../shosai-core/tests/fixtures/epub-conformance/table.epub")
                .to_vec(),
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
        let ContentNode::Table { row_groups, .. } = table else {
            unreachable!();
        };
        let nested = row_groups
            .iter()
            .flat_map(|group| &group.rows)
            .flat_map(|row| &row.cells)
            .flat_map(|cell| &cell.children)
            .collect::<Vec<_>>();
        assert!(nested.iter().any(|node| {
            matches!(node, ContentNode::Paragraph(spans, _) if
                spans.iter().any(|span| span.link.as_deref() == Some("#spanning-table")))
        }));
        let image_path = nested.iter().find_map(|node| match node {
            ContentNode::Image { src, .. } => Some(src.as_str()),
            _ => None,
        });
        assert_eq!(image_path, Some("OEBPS/Images/pixel.png"));

        let mut handles = HashMap::new();
        cache_epub_image_handles(&mut handles, std::iter::once(table), &|path| {
            epub.resource(path).map(|resource| resource.bytes())
        });
        assert!(handles.contains_key("OEBPS/Images/pixel.png"));
    }

    #[test]
    fn cached_image_alt_matches_remain_visibly_highlighted() {
        let highlights = [
            SearchHighlight {
                start: 11,
                end: 13,
                current: false,
            },
            SearchHighlight {
                start: 12,
                end: 14,
                current: true,
            },
        ];

        assert_eq!(image_alt_highlight("diagram", 10, &highlights), Some(true));
        assert_eq!(image_alt_highlight("diagram", 20, &highlights), None);
    }

    #[test]
    fn cached_image_alt_highlight_does_not_change_element_geometry() {
        let node = ContentNode::Image {
            src: "image.png".into(),
            alt: "diagram".into(),
            style: Default::default(),
            caption: Vec::new(),
            caption_style: None,
            intrinsic_size: Some(shosai_core::epub::render::ImageSize {
                width: 200,
                height: 100,
            }),
            kind: Some(shosai_core::epub::render::ImageKind::Raster),
        };
        let handles = HashMap::from([(
            "image.png".to_string(),
            EpubImageHandle::Raster(image::Handle::from_rgba(200, 100, vec![0; 80_000])),
        )]);
        let highlighted = [SearchHighlight {
            start: 0,
            end: 7,
            current: true,
        }];
        let layout_bounds = |highlights: &[SearchHighlight]| {
            let element = render_epub_image(
                &node,
                &I18n::new(LanguagePreference::English),
                16.0,
                ReaderTheme::Light.palette(),
                &handles,
                400.0,
                Some(300.0),
                Some(300.0),
                0,
                highlights,
                None,
                1.0,
            );
            let mut renderer = iced::Renderer::Secondary(iced_tiny_skia::Renderer::new(
                Font::DEFAULT,
                iced::Pixels(16.0),
            ));
            let mut interface = iced_runtime::UserInterface::build(
                element,
                Size::new(400.0, 300.0),
                iced_runtime::user_interface::Cache::new(),
                &mut renderer,
            );
            let mut recorded = RecordedWidgetIds::default();
            interface.operate(&renderer, &mut recorded);
            recorded.container_bounds
        };

        assert_eq!(layout_bounds(&[]), layout_bounds(&highlighted));
    }

    #[test]
    fn undecodable_raster_fallback_keeps_intrinsic_image_bounds() {
        let node = ContentNode::Image {
            src: "undecodable.png".into(),
            alt: "very long fallback text ".repeat(200),
            style: Default::default(),
            caption: Vec::new(),
            caption_style: None,
            intrinsic_size: Some(shosai_core::epub::render::ImageSize {
                width: 20,
                height: 10,
            }),
            kind: Some(shosai_core::epub::render::ImageKind::Raster),
        };
        let element = render_epub_image(
            &node,
            &I18n::new(LanguagePreference::English),
            16.0,
            ReaderTheme::Light.palette(),
            &HashMap::new(),
            400.0,
            Some(300.0),
            Some(300.0),
            0,
            &[],
            None,
            1.0,
        );
        let mut renderer = iced::Renderer::Secondary(iced_tiny_skia::Renderer::new(
            Font::DEFAULT,
            iced::Pixels(16.0),
        ));
        let mut interface = iced_runtime::UserInterface::build(
            element,
            Size::new(400.0, 300.0),
            iced_runtime::user_interface::Cache::new(),
            &mut renderer,
        );
        let mut recorded = RecordedWidgetIds::default();
        interface.operate(&renderer, &mut recorded);

        assert!(
            recorded
                .container_bounds
                .iter()
                .any(|bounds| bounds.width == 20.0 && bounds.height == 10.0)
        );
    }

    #[test]
    fn search_highlights_split_unicode_text_at_character_offsets() {
        let highlights = [SearchHighlight {
            start: 11,
            end: 13,
            current: true,
        }];

        assert_eq!(
            highlighted_fragments("aé日z", 10, &highlights),
            vec![
                ("a".to_string(), None),
                ("é日".to_string(), Some(true)),
                ("z".to_string(), None),
            ]
        );
    }

    #[test]
    fn code_search_highlights_preserve_syntax_colors() {
        let code = "fn main() {\n    let target = true;\n}";
        let syntax_lines =
            shosai_core::highlight::highlight_code(code, Some("rust"), "base16-ocean.dark")
                .unwrap();
        let target_offset = code.find("target").unwrap();
        let highlights = [SearchHighlight {
            start: target_offset,
            end: target_offset + "target".len(),
            current: true,
        }];
        let mut code_offset = 0;
        let fragments = syntax_lines
            .iter()
            .flat_map(|line| highlighted_code_line(line, &mut code_offset, &highlights))
            .collect::<Vec<_>>();

        assert!(fragments.iter().any(|fragment| {
            fragment.text == "target" && fragment.search_highlight == Some(true)
        }));
        let mut colors = fragments
            .iter()
            .map(|fragment| fragment.color)
            .collect::<Vec<_>>();
        colors.sort_unstable();
        colors.dedup();
        assert!(
            colors.len() > 1,
            "syntax foreground colors must be retained"
        );
    }

    #[test]
    fn computed_heading_spans_survive_pagination_search_and_app_font_resolution() {
        let nodes = shosai_core::epub::render::parse_chapter_xhtml(
            r#"<html><body><h2 style="font-size:40px;font-style:italic;font-family:monospace">
                Styled <span style="font-size:20px;font-weight:normal">plain</span>
            </h2></body></html>"#,
            "",
            &Default::default(),
        );
        let ContentNode::Heading {
            level,
            spans,
            style,
        } = &nodes[0]
        else {
            panic!("expected heading presentation");
        };

        let pages =
            crate::epub::paginate_epub_chapter(&nodes, None, 16.0, 1.6, Size::new(240.0, 180.0));
        let ContentNode::Heading {
            spans: paginated_spans,
            ..
        } = &pages[0][0].node
        else {
            panic!("expected paginated heading");
        };
        assert_eq!(paginated_spans, spans);
        assert_eq!(pages[0][0].text_offset, 0);
        let search_text = shosai_core::search::extract_text_from_nodes(&nodes);
        assert_eq!(search_text, "Styled plain\n");
        let mut matches = Vec::new();
        shosai_core::search::find_matches_in_text_pub(&search_text, "plain", 0, &mut matches);
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].offset, 7);
        assert_eq!(matches[0].length, 5);

        let heading_size = epub_heading_font_size(*level, style, 16.0);
        assert!((heading_size - 40.0).abs() < 0.01);
        assert!((epub_span_size(heading_size, &spans[0]) - 40.0).abs() < 0.01);
        assert!((epub_span_size(heading_size, &spans[1]) - 20.0).abs() < 0.01);
        let inherited_font = epub_span_font(&spans[0]);
        assert_eq!(inherited_font.family, iced::font::Family::Monospace);
        assert_eq!(inherited_font.weight, iced::font::Weight::Bold);
        assert_eq!(inherited_font.style, iced::font::Style::Italic);
        let overridden_font = epub_span_font(&spans[1]);
        assert_eq!(overridden_font.family, iced::font::Family::Monospace);
        assert_eq!(overridden_font.weight, iced::font::Weight::Normal);
        assert_eq!(overridden_font.style, iced::font::Style::Italic);
    }

    #[test]
    fn declared_rtl_direction_forces_bidi_shaping_when_text_starts_in_english() {
        use cosmic_text::{Attrs, Buffer, Metrics, Shaping};

        let (isolate, pop_isolate) =
            text_direction_controls(shosai_core::epub::style::TextDirection::Rtl);
        let source = "English 123 עברית";
        let shaped = format!("{isolate}{source}{pop_isolate}");
        let mut font_system = crate::epub::text_shaping::font_system();
        let mut buffer = Buffer::new(&mut font_system, Metrics::new(20.0, 28.0));
        buffer.set_text(
            &mut font_system,
            &shaped,
            &Attrs::new(),
            Shaping::Advanced,
            None,
        );
        buffer.shape_until_scroll(&mut font_system, false);

        let english = isolate.len_utf8()..isolate.len_utf8() + "English".len();
        let english_levels = buffer
            .layout_runs()
            .flat_map(|run| run.glyphs.iter())
            .filter(|glyph| glyph.start < english.end && glyph.end > english.start)
            .map(|glyph| glyph.level.number())
            .collect::<Vec<_>>();
        assert!(!english_levels.is_empty());
        assert!(
            english_levels.iter().all(|level| *level == 2),
            "English must be nested in the declared RTL embedding, got {english_levels:?}"
        );
    }
}
