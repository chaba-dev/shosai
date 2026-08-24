use super::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EpubLinkTarget {
    Internal,
    External,
    Unsupported,
}

fn classify_link_target(href: &str) -> EpubLinkTarget {
    let Some(scheme) = link_scheme(href) else {
        return EpubLinkTarget::Internal;
    };
    if ["http", "https", "mailto"]
        .iter()
        .any(|allowed| scheme.eq_ignore_ascii_case(allowed))
    {
        EpubLinkTarget::External
    } else {
        EpubLinkTarget::Unsupported
    }
}

fn link_scheme(href: &str) -> Option<&str> {
    let colon = href.find(':')?;
    if href[..colon].find(['/', '?', '#']).is_some() {
        return None;
    }
    let scheme = &href[..colon];
    let mut characters = scheme.chars();
    (characters
        .next()
        .is_some_and(|character| character.is_ascii_alphabetic())
        && characters.all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '+' | '-' | '.')
        }))
    .then_some(scheme)
}

pub(super) fn handle_link_click(state: &mut State, href: &str) -> Task<Message> {
    match classify_link_target(href) {
        EpubLinkTarget::External => {
            if let Err(error) = open::that(href) {
                eprintln!("warning: failed to open URL: {error}");
            }
        }
        EpubLinkTarget::Internal => {
            if let Some(OpenDocument::Epub(document)) = &state.document
                && let Some((chapter, offset)) = document.resolve_location(state.current_page, href)
            {
                return navigate_to_epub_location(state, chapter, offset);
            }
        }
        EpubLinkTarget::Unsupported => {}
    }
    Task::none()
}

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn epub_links_allow_only_internal_http_https_and_mail_targets() {
        for href in [
            "#note",
            "#part:two",
            "chapter.xhtml#note",
            "Text/foo:bar.xhtml#target",
            "Text/section/chapter:one.xhtml",
            "../chapter.xhtml",
        ] {
            assert_eq!(classify_link_target(href), EpubLinkTarget::Internal);
        }
        for href in [
            "https://example.com",
            "HTTP://example.com",
            "mailto:reader@example.com",
        ] {
            assert_eq!(classify_link_target(href), EpubLinkTarget::External);
        }
        for href in [
            "javascript:alert(1)",
            "file:///etc/passwd",
            "data:text/html,unsafe",
            "ftp://example.com/book",
        ] {
            assert_eq!(classify_link_target(href), EpubLinkTarget::Unsupported);
        }
    }
}
