use super::*;
use iced::widget::column;

pub(super) fn continuous_epub_content_view<'a>(
    state: &'a State,
    doc: &'a EpubDoc,
    tab_id: u64,
    activation: u64,
) -> Element<'a, Message> {
    let mut chapters = column![].spacing(32).padding(20).width(Length::Fill);
    for (chapter_index, presentation) in doc.presentation().chapters().iter().enumerate() {
        let nodes = presentation.nodes();
        let mut chapter = column![].spacing(state.font_size * state.line_spacing);
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
                .width(Length::Fill),
            );
            text_offset += content_node_text_len(node) + 1;
        }
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

pub(super) fn continuous_epub_content_width(window_width: f32, show_bookmarks_panel: bool) -> f32 {
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
            ContentNode::Image { src, .. } => {
                if handles.contains_key(src) {
                    continue;
                }
                let Some(data) = resource_bytes(src) else {
                    continue;
                };
                let Ok(image) = ::image::load_from_memory(data) else {
                    continue;
                };
                let rgba = image.to_rgba8();
                let (width, height) = rgba.dimensions();
                handles.insert(
                    src.clone(),
                    EpubImageHandle(image::Handle::from_rgba(width, height, rgba.into_raw())),
                );
            }
            ContentNode::BlockQuote { children, .. } => {
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
        let image_only = matches!(
            epub_page.nodes.as_slice(),
            [EpubPageNode {
                node: ContentNode::Image { .. },
                ..
            }]
        );
        let mut page = column![].spacing(line_gap).width(Length::Fill);
        if let Some(title) = &epub_page.title {
            page = page.push(text(title.clone()).size(font_size * 1.5).color(text_color));
        }
        for page_node in &epub_page.nodes {
            page = page.push(render_content_node(
                &page_node.node,
                &state.i18n,
                font_size,
                state.theme.palette(),
                &state.epub_image_handles,
                true,
                text_width,
                Some(epub_page_size(state).height),
                page_node.text_offset,
                &highlights,
                fonts,
                state.window_scale_factor,
            ));
        }
        if !image_only {
            page = page.push(iced::widget::Space::new().height(Length::Fill));
        }
        page = page.push(
            text(format!("{}", page_index + 1))
                .size(EPUB_PAGE_NUMBER_SIZE)
                .color(iced::Color {
                    a: 0.55,
                    ..text_color
                }),
        );
        let mut page_content = container(page).width(Length::Fill).height(Length::Fill);
        if !image_only {
            page_content = page_content.max_width(text_width);
        }
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

pub(super) fn content_starts_with_heading(nodes: &[ContentNode], title: &str) -> bool {
    nodes.first().is_some_and(|node| match node {
        ContentNode::Heading { spans, .. } => {
            spans
                .iter()
                .map(|span| span.text.as_str())
                .collect::<String>()
                .trim()
                == title.trim()
        }
        _ => false,
    })
}

#[allow(clippy::too_many_arguments)]
pub(super) fn render_content_node<'a>(
    node: &ContentNode,
    i18n: &I18n,
    font_size: f32,
    palette: ReaderPalette,
    image_handles: &HashMap<String, EpubImageHandle>,
    fill_images: bool,
    available_width: f32,
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
            let mut col = column![].spacing(EPUB_BLOCKQUOTE_SPACING);
            let mut child_offset = text_offset;
            for child in children {
                col = col.push(render_content_node(
                    child,
                    i18n,
                    font_size,
                    palette,
                    image_handles,
                    fill_images,
                    (available_width - style.margin_left_em.unwrap_or(1.0) * font_size).max(1.0),
                    available_height,
                    child_offset,
                    highlights,
                    fonts,
                    scale,
                ));
                child_offset += content_node_text_len(child) + 1;
            }
            let margin = style.margin_left_em.unwrap_or(1.0) * font_size;
            container(col)
                .width(Length::Fill)
                .padding(iced::Padding {
                    left: margin,
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
            let table_width = crate::epub::epub_table_layout_width(row_groups, available_width);
            let table_content_width =
                (table_width - style.margin_left_em.unwrap_or(0.0) * font_size).max(1.0);
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
            for table_row in row_groups.iter().flat_map(|group| &group.rows) {
                let mut rendered_row = row![].spacing(EPUB_BLOCKQUOTE_SPACING);
                for (cell_index, cell) in table_row.cells.iter().enumerate() {
                    let mut rendered_cell = column![].spacing(EPUB_TABLE_CELL_SPACING);
                    for (child_index, child) in cell.children.iter().enumerate() {
                        if cell.block_starts.contains(&child_index) {
                            table_offset += 1;
                        }
                        rendered_cell = rendered_cell.push(render_content_node(
                            child,
                            i18n,
                            font_size,
                            palette,
                            image_handles,
                            fill_images,
                            crate::epub::epub_table_cell_content_width(
                                table_row,
                                cell_index,
                                table_content_width,
                            ),
                            available_height,
                            table_offset,
                            highlights,
                            fonts,
                            scale,
                        ));
                        table_offset += content_node_text_len(child);
                    }
                    let header = cell.header;
                    rendered_row = rendered_row.push(
                        container(rendered_cell)
                            .width(Length::FillPortion(cell.column_span.max(1)))
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
                            }),
                    );
                    if cell_index + 1 < table_row.cells.len() {
                        table_offset += 1;
                    }
                }
                table = table.push(rendered_row);
                table_offset += 1;
            }
            let mut table = container(table).width(Length::Fixed(table_width));
            if let Some(margin) = style.margin_left_em {
                table = table.padding(iced::Padding {
                    left: margin * font_size,
                    ..iced::Padding::ZERO
                });
            }
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
                let num_text = format!("  {}. ", start + i);
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

        ContentNode::Image { src, alt } => render_epub_image(
            src,
            alt,
            i18n,
            font_size,
            palette,
            image_handles,
            fill_images,
            text_offset,
            highlights,
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

pub(super) fn math_highlight_state(
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

pub(super) fn math_highlight_color(
    palette: ReaderPalette,
    highlight: Option<bool>,
) -> Option<iced::Color> {
    highlight.map(|current| {
        if current {
            palette.current_search_highlight
        } else {
            palette.search_highlight
        }
    })
}

pub(super) fn epub_heading_font_size(
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
    src: &str,
    alt: &str,
    i18n: &I18n,
    font_size: f32,
    palette: ReaderPalette,
    image_handles: &HashMap<String, EpubImageHandle>,
    fill: bool,
    text_offset: usize,
    highlights: &[SearchHighlight],
) -> Element<'a, Message> {
    let text_color = palette.text;
    if let Some(handle) = image_handles.get(src) {
        let mut rendered = image(&handle.0)
            .content_fit(iced::ContentFit::ScaleDown)
            .width(Length::Fill);
        if fill {
            rendered = rendered.height(Length::Fill);
        }
        let mut image_container = container(rendered)
            .width(Length::Fill)
            .center_x(Length::Fill);
        if fill {
            image_container = image_container.height(Length::Fill);
        }
        if image_alt_highlight(alt, text_offset, highlights).is_some() {
            return column![
                image_container,
                render_highlighted_text_with_font(
                    alt,
                    text_offset,
                    font_size,
                    palette,
                    Font::DEFAULT,
                    highlights,
                )
            ]
            .into();
        }
        return image_container.into();
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
    rich_text(spans).into()
}

pub(super) fn image_alt_highlight(
    alt: &str,
    text_offset: usize,
    highlights: &[SearchHighlight],
) -> Option<bool> {
    highlighted_fragments(alt, text_offset, highlights)
        .into_iter()
        .filter_map(|(_, highlight)| highlight)
        .max()
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
pub(super) struct HighlightedCodeFragment {
    pub(super) text: String,
    pub(super) color: (u8, u8, u8),
    bold: bool,
    italic: bool,
    pub(super) search_highlight: Option<bool>,
}

pub(super) fn highlighted_code_line(
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

    rich_text(rich_spans)
        .wrapping(epub_fallback_wrapping())
        .on_link_click(epub_link_clicked)
        .into()
}

pub(super) fn color_rgba(color: iced::Color) -> [u8; 4] {
    [
        (color.r * 255.0).round() as u8,
        (color.g * 255.0).round() as u8,
        (color.b * 255.0).round() as u8,
        (color.a * 255.0).round() as u8,
    ]
}

pub(super) fn epub_fallback_wrapping() -> iced::widget::text::Wrapping {
    iced::widget::text::Wrapping::WordOrGlyph
}

#[allow(clippy::too_many_arguments)]
pub(super) fn render_inline_math_spans<'a>(
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

pub(super) fn native_epub_run(
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

pub(super) fn native_epub_highlight_color(palette: ReaderPalette, current: bool) -> [u8; 4] {
    color_rgba(if current {
        palette.current_search_highlight
    } else {
        palette.search_highlight
    })
}

pub(super) fn epub_link_clicked(href: String) -> Message {
    Message::LinkClicked(href)
}

pub(super) fn text_direction_controls(
    direction: shosai_core::epub::style::TextDirection,
) -> (char, char) {
    let isolate = match direction {
        shosai_core::epub::style::TextDirection::Ltr => '\u{2066}',
        shosai_core::epub::style::TextDirection::Rtl => '\u{2067}',
    };
    (isolate, '\u{2069}')
}

pub(super) fn styled_epub_span<'a>(
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

pub(super) fn epub_span_font(text_span: &shosai_core::epub::render::TextSpan) -> Font {
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

pub(super) fn epub_span_size(
    font_size: f32,
    text_span: &shosai_core::epub::render::TextSpan,
) -> f32 {
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

pub(super) fn highlighted_fragments(
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
