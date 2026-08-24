use super::*;

pub(super) fn navigate_to_epub_location(
    state: &mut State,
    chapter: usize,
    offset: usize,
) -> Task<Message> {
    if uses_paginated_epub_layout(state) {
        state.epub_page = epub_page_for_location(state, chapter, offset);
        sync_epub_location(state);
        state.epub_offset = offset;
        save_reading_state(state);
        return Task::none();
    }
    state.current_page = chapter;
    state.epub_page = 0;
    state.epub_offset = offset;
    state.page_input = format!("{}", state.current_page + 1);
    save_reading_state(state);
    content_navigation_task(state)
}

pub(super) fn turn_epub_page(state: &mut State, forward: bool) -> Task<Message> {
    let step = if epub_uses_spread(state) { 2 } else { 1 };
    let page = if forward {
        let next = epub_spread_start(state, state.epub_page).saturating_add(step);
        if next >= state.epub_pages.len() {
            return Task::none();
        }
        next
    } else if state.epub_page > 0 {
        epub_spread_start(state, state.epub_page).saturating_sub(step)
    } else {
        return Task::none();
    };
    perf::begin_page_turn(state, page);
    state.epub_page = page;
    sync_epub_location(state);
    save_reading_state(state);
    Task::none()
}

pub(super) fn can_turn_epub_page(state: &State, forward: bool) -> bool {
    if forward {
        let step = if epub_uses_spread(state) { 2 } else { 1 };
        epub_spread_start(state, state.epub_page).saturating_add(step) < state.epub_pages.len()
    } else {
        state.epub_page > 0
    }
}

pub(super) fn sync_epub_location(state: &mut State) {
    if let Some(page) = state.epub_pages.get(state.epub_page) {
        state.current_page = page.chapter;
        state.epub_offset = page.nodes.first().map_or(0, |node| node.text_offset);
        state.page_input = (state.epub_page + 1).to_string();
        update_bookmark_status(state);
    }
}

pub(super) fn epub_page_for_location(state: &State, chapter: usize, offset: usize) -> usize {
    epub_page_for_pages(&state.epub_pages, chapter, offset)
}

pub(super) fn epub_page_for_pages(pages: &[EpubPage], chapter: usize, offset: usize) -> usize {
    pages
        .iter()
        .enumerate()
        .filter(|(_, page)| {
            page.chapter == chapter
                && page
                    .nodes
                    .first()
                    .is_none_or(|node| node.text_offset <= offset)
        })
        .map(|(index, _)| index)
        .next_back()
        .or_else(|| pages.iter().position(|page| page.chapter == chapter))
        .unwrap_or(0)
}
