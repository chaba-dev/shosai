use super::*;

pub fn update(state: &mut State, message: Message) -> Task<Message> {
    match message {
        Message::Initialized(Ok(initialized)) => {
            let InitializedState {
                store,
                window_geometry: geometry,
            } = initialized;
            let pool = store.pool().clone();
            state.library = Some(Library::new(pool.clone()));
            state.bookmark_store = Some(BookmarkStore::new(pool));
            state.reading_state = Some(store);
            state.storage_initializing = false;
            state.saved_window_geometry = geometry;
            let geometry_task =
                if let (Some(id), Some((size, position))) = (state.window_id, geometry) {
                    state.window_size = size;
                    state.window_position = Some(position);
                    Task::batch([window::resize(id, size), window::move_to(id, position)])
                } else {
                    Task::none()
                };
            if let Some(pending) = state.pending_open.take() {
                return Task::batch([geometry_task, Task::done(pending.into_message())]);
            }
            return Task::batch([geometry_task, reset_library(state)]);
        }

        Message::Initialized(Err(error)) => {
            eprintln!("warning: failed to open reading state database: {error}");
            state.storage_initializing = false;
            state.library_loading = false;
            state.storage_error = Some(format!("Failed to initialize storage: {error}"));
            if let Some(pending) = state.pending_open.take() {
                return Task::done(pending.into_message());
            }
        }

        Message::OpenFile => {
            return Task::perform(
                async {
                    let file = rfd::AsyncFileDialog::new()
                        .add_filter("Ebooks", &["pdf", "epub", "cbz"])
                        .add_filter("PDF", &["pdf"])
                        .add_filter("EPUB", &["epub"])
                        .add_filter("CBZ", &["cbz"])
                        .set_title("Open File")
                        .pick_file()
                        .await;

                    file.map(|f| f.path().to_path_buf())
                },
                Message::FileSelected,
            );
        }

        Message::FileSelected(Some(path)) => {
            if state.storage_initializing {
                state.pending_open = Some(PendingOpen::FileSelected(path));
                return Task::none();
            }
            return open_document(state, path);
        }

        Message::FileSelected(None) => {}

        Message::NextPage => {
            if uses_paginated_epub_layout(state) {
                return turn_epub_page(state, true);
            }
            if let Some(page) = next_page_location(state) {
                state.current_page = page;
                if matches!(state.document, Some(OpenDocument::Epub(_))) {
                    state.epub_offset = 0;
                }
                state.page_input = format!("{}", state.current_page + 1);
                save_reading_state(state);
                return content_navigation_task(state);
            }
        }

        Message::PrevPage => {
            if uses_paginated_epub_layout(state) {
                return turn_epub_page(state, false);
            }
            if let Some(page) = previous_page_location(state) {
                state.current_page = page;
                if matches!(state.document, Some(OpenDocument::Epub(_))) {
                    state.epub_offset = 0;
                }
                state.page_input = format!("{}", state.current_page + 1);
                save_reading_state(state);
                return content_navigation_task(state);
            }
        }

        Message::PageInputChanged(value) => {
            state.page_input = value;
        }

        Message::GoToPage => {
            if let Ok(page_num) = state.page_input.parse::<usize>()
                && page_num >= 1
                && uses_paginated_epub_layout(state)
                && page_num <= state.epub_pages.len()
            {
                state.epub_page = page_num - 1;
                sync_epub_location(state);
                save_reading_state(state);
                return Task::none();
            }
            if let Ok(page_num) = state.page_input.parse::<usize>()
                && page_num >= 1
                && page_num <= state.total_pages
            {
                state.current_page = page_num - 1;
                state.epub_page = 0;
                state.epub_offset = 0;
                save_reading_state(state);
                state.page_input = format!("{}", state.current_page + 1);
                return content_navigation_task(state);
            }
            state.page_input = if uses_paginated_epub_layout(state) {
                (state.epub_page + 1).to_string()
            } else {
                (state.current_page + 1).to_string()
            };
        }

        Message::FirstPage => {
            if uses_paginated_epub_layout(state) && !state.epub_pages.is_empty() {
                state.epub_page = 0;
                sync_epub_location(state);
                save_reading_state(state);
                return Task::none();
            }
            if state.document.is_some() {
                state.current_page = 0;
                state.epub_page = 0;
                state.epub_offset = 0;
                state.page_input = "1".to_string();
                save_reading_state(state);
                return content_navigation_task(state);
            }
        }

        Message::LastPage => {
            if uses_paginated_epub_layout(state) && !state.epub_pages.is_empty() {
                state.epub_page = state.epub_pages.len() - 1;
                sync_epub_location(state);
                save_reading_state(state);
                return Task::none();
            }
            if state.document.is_some() && state.total_pages > 0 {
                state.current_page = state.total_pages - 1;
                state.epub_page = 0;
                state.epub_offset = 0;
                state.page_input = state.total_pages.to_string();
                save_reading_state(state);
                return content_navigation_task(state);
            }
        }

        Message::ToggleReadingMode => {
            invalidate_continuous_layout(state);
            state.reading_mode = match state.reading_mode {
                ReadingMode::Paginated => ReadingMode::Continuous,
                ReadingMode::Continuous => ReadingMode::Paginated,
            };
            state.continuous_pages.clear();
            state.continuous_visible.clear();
            state.continuous_chapters.clear();
            state.render_generation = state.render_generation.wrapping_add(1);
            let task = refresh_content(state);
            state.page_input = if uses_paginated_epub_layout(state) {
                (state.epub_page + 1).to_string()
            } else {
                (state.current_page + 1).to_string()
            };
            return task;
        }

        Message::ContinuousScrolled {
            tab_id,
            activation,
            offset,
        } => {
            if state.reading_mode == ReadingMode::Continuous
                && state.active_tab_id == Some(tab_id)
                && state.continuous_activation == activation
            {
                return iced::advanced::widget::operate(ContinuousItemOperation::resolve(
                    tab_id,
                    activation,
                    state.total_pages,
                    offset,
                ))
                .map(move |(page, _, _)| Message::ContinuousItemResolved {
                    tab_id,
                    activation,
                    page,
                });
            }
        }

        Message::ContinuousItemResolved {
            tab_id,
            activation,
            page,
        } => {
            if state.reading_mode == ReadingMode::Continuous
                && state.active_tab_id == Some(tab_id)
                && state.continuous_activation == activation
                && page < state.total_pages
                && page != state.current_page
            {
                state.current_page = page;
                state.epub_page = 0;
                state.epub_offset = 0;
                state.page_input = (page + 1).to_string();
                save_reading_state(state);
                update_bookmark_status(state);
                return reconcile_continuous_rasters(state);
            }
        }

        Message::ContinuousItemVisibility {
            tab_id,
            activation,
            page,
            visible,
        } => {
            if state.active_tab_id != Some(tab_id) || state.continuous_activation != activation {
                return Task::none();
            }
            if visible {
                state.continuous_visible.insert(page);
            } else {
                state.continuous_visible.remove(&page);
            }
            return reconcile_continuous_rasters(state);
        }

        Message::ContinuousNavigationMeasured {
            tab_id,
            activation,
            offset,
            tail_extent,
        } => {
            if state.active_tab_id != Some(tab_id) || state.continuous_activation != activation {
                return Task::none();
            }
            if (state.continuous_tail_extent - tail_extent).abs() > 1.0 {
                state.continuous_tail_extent = tail_extent;
                return Task::done(Message::ContinuousNavigationMeasured {
                    tab_id,
                    activation,
                    offset,
                    tail_extent,
                });
            }
            return iced::widget::operation::scroll_to(
                continuous_scroll_id(tab_id, activation),
                iced::widget::operation::AbsoluteOffset {
                    x: None,
                    y: Some(offset),
                },
            );
        }

        Message::SelectTab(index) => return select_tab(state, index),
        Message::CloseTab(index) => return close_tab(state, index),
        Message::NextTab => {
            if !state.tabs.is_empty() {
                let next = (state.active_tab.unwrap_or(0) + 1) % state.tabs.len();
                return select_tab(state, next);
            }
        }

        Message::ZoomIn => {
            if matches!(
                state.document,
                Some(OpenDocument::Pdf(_)) | Some(OpenDocument::Cbz(_))
            ) {
                let new_scale = zoom_step_scale(state, 0.25);
                state.zoom = ZoomMode::Manual(new_scale);
                invalidate_continuous_rasters(state);
                save_reading_state(state);
                return refresh_content(state);
            }
        }

        Message::ZoomOut => {
            if matches!(
                state.document,
                Some(OpenDocument::Pdf(_)) | Some(OpenDocument::Cbz(_))
            ) {
                let new_scale = zoom_step_scale(state, -0.25);
                state.zoom = ZoomMode::Manual(new_scale);
                invalidate_continuous_rasters(state);
                save_reading_state(state);
                return refresh_content(state);
            }
        }

        Message::SetZoomFitWidth => {
            state.zoom = ZoomMode::FitWidth;
            invalidate_continuous_rasters(state);
            save_reading_state(state);
            return refresh_content(state);
        }

        Message::SetZoomFitPage => {
            state.zoom = ZoomMode::FitPage;
            invalidate_continuous_rasters(state);
            save_reading_state(state);
            return refresh_content(state);
        }

        Message::FontSizeUp => {
            state.font_size = (state.font_size + 2.0).min(48.0);
            invalidate_continuous_layout(state);
            if uses_paginated_epub_layout(state) {
                return refresh_content(state);
            }
            return scroll_to_current_page(state);
        }

        Message::FontSizeDown => {
            state.font_size = (state.font_size - 2.0).max(8.0);
            invalidate_continuous_layout(state);
            if uses_paginated_epub_layout(state) {
                return refresh_content(state);
            }
            return scroll_to_current_page(state);
        }

        Message::CycleTheme => {
            state.theme = state.theme.next();
        }

        Message::ToggleReaderSettings => {
            invalidate_continuous_layout(state);
            state.show_reader_settings = !state.show_reader_settings;
            state.show_reader_more = false;
            state.show_bookmarks_panel = false;
            return reader_layout_changed_task(state);
        }

        Message::ToggleReaderMore => {
            invalidate_continuous_layout(state);
            state.show_reader_more = !state.show_reader_more;
            state.show_reader_settings = false;
            state.show_bookmarks_panel = false;
            return reader_layout_changed_task(state);
        }

        Message::LinkClicked(href) => {
            return handle_link_click(state, &href);
        }

        // Library
        Message::ShowLibrary => {
            invalidate_continuous_layout(state);
            state.screen = Screen::Library;
            state.show_reader_settings = false;
            state.show_reader_more = false;
            return Task::done(Message::RefreshLibrary);
        }

        Message::RefreshLibrary => {
            return reset_library(state);
        }

        Message::LoadMoreLibrary => {
            if state.library_has_more && !state.library_loading {
                return load_library_page(state, true);
            }
        }

        Message::LibraryIndexLoaded { generation, ids } => {
            if generation != state.library_generation {
                return Task::none();
            }
            state.library_book_ids = Arc::new(ids);
            state.library_offset = 0;
            state.library_has_more = !state.library_book_ids.is_empty();
            if state.library_has_more {
                return load_library_page(state, false);
            }
            state.library_books.clear();
            state.library_loading = false;
        }

        Message::LibraryLoaded {
            generation,
            offset,
            next_offset,
            page,
        } => {
            if generation != state.library_generation || offset != state.library_offset {
                return Task::none();
            }
            if offset > 0 {
                state.library_books.extend(page.books);
            } else {
                state.library_books = page.books;
            }
            state.library_offset = next_offset;
            state.library_has_more = next_offset < state.library_book_ids.len();
            state.library_loading = false;
        }

        Message::ImportFile => {
            if state.library.is_none() {
                return Task::none();
            }
            return Task::perform(
                async {
                    let file = rfd::AsyncFileDialog::new()
                        .add_filter("Ebooks", &["pdf", "epub", "cbz"])
                        .set_title("Import to Library")
                        .pick_file()
                        .await;
                    file.map(|f| f.path().to_path_buf())
                },
                |path| {
                    if let Some(p) = path {
                        Message::OpenBook(p.to_string_lossy().to_string())
                    } else {
                        Message::RefreshLibrary // no-op refresh
                    }
                },
            );
        }

        Message::ImportDirectory => {
            if let Some(lib) = state.library.clone() {
                return Task::perform(
                    async move {
                        let dir = rfd::AsyncFileDialog::new()
                            .set_title("Import Directory")
                            .pick_folder()
                            .await;
                        if let Some(d) = dir {
                            let _ = lib.import_directory(d.path()).await;
                        }
                    },
                    |_| Message::RefreshLibrary,
                );
            }
        }

        Message::OpenBook(file_path) => {
            let path = PathBuf::from(&file_path);
            if state.storage_initializing {
                state.pending_open = Some(PendingOpen::LibraryBook(path));
                return Task::none();
            }
            // Import to library if not already there.
            if let Some(lib) = state.library.clone() {
                let p = path.clone();
                // Fire-and-forget import.
                tokio::task::spawn(async move {
                    let _ = lib.import_file(&p).await;
                });
            }
            state.screen = Screen::Reader;
            return open_document(state, path);
        }

        Message::RemoveBook(id) => {
            if let Some(lib) = state.library.clone() {
                return Task::perform(
                    async move {
                        let _ = lib.remove(id).await;
                    },
                    |_| Message::RefreshLibrary,
                );
            }
        }

        Message::LibrarySearchChanged(query) => {
            state.library_search = query;
            return reset_library(state);
        }

        Message::LibraryFilterChanged(filter) => {
            state.library_filter = filter;
            return reset_library(state);
        }

        Message::LibraryActivityTick => {
            if library_activity_active(state) {
                state.library_activity_progress =
                    (state.library_activity_progress + LIBRARY_ACTIVITY_STEP).min(1.0);
            }
        }

        // Bookmarks
        Message::ToggleBookmark => {
            if let (Some(path), Some(store)) = (&state.file_path, &state.bookmark_store) {
                let page_title = format!("Page {}", state.current_page + 1);
                match store.toggle_at(
                    path,
                    state.current_page,
                    current_epub_offset(state),
                    Some(&page_title),
                ) {
                    Ok(Some(_)) => state.current_page_bookmarked = true,
                    Ok(None) => state.current_page_bookmarked = false,
                    Err(e) => eprintln!("warning: failed to toggle bookmark: {e}"),
                }
                return refresh_bookmarks(state);
            }
        }

        Message::ToggleBookmarksPanel => {
            invalidate_continuous_layout(state);
            state.show_bookmarks_panel = !state.show_bookmarks_panel;
            state.show_reader_settings = false;
            state.show_reader_more = false;
            if state.show_bookmarks_panel {
                return Task::batch([refresh_bookmarks(state), reader_layout_changed_task(state)]);
            }
            return reader_layout_changed_task(state);
        }

        Message::BookmarksLoaded {
            tab_id,
            file_path,
            bookmarks,
        } => {
            if state.active_tab_id != Some(tab_id) || state.file_path.as_ref() != Some(&file_path) {
                return Task::none();
            }
            state.bookmarks = bookmarks;
            // Update current page bookmark status.
            if let Some(path) = &state.file_path
                && let Some(store) = &state.bookmark_store
            {
                state.current_page_bookmarked =
                    store.is_bookmarked_at(path, state.current_page, current_epub_offset(state));
            }
        }

        Message::GoToBookmark(page, location_offset) => {
            if uses_paginated_epub_layout(state) {
                state.epub_page = epub_page_for_location(state, page, location_offset.unwrap_or(0));
                sync_epub_location(state);
                state.epub_offset = location_offset.unwrap_or(0);
                save_reading_state(state);
                return Task::none();
            }
            state.current_page = page;
            state.epub_page = 0;
            state.epub_offset = location_offset.unwrap_or(0);
            state.page_input = format!("{}", page + 1);
            save_reading_state(state);
            update_bookmark_status(state);
            return content_navigation_task(state);
        }

        Message::StartEditNote(id, existing) => {
            state.editing_note_id = Some(id);
            state.editing_note_text = existing;
        }

        Message::EditNoteChanged(text) => {
            state.editing_note_text = text;
        }

        Message::SaveNote => {
            if let (Some(id), Some(store)) = (state.editing_note_id, &state.bookmark_store) {
                let note = if state.editing_note_text.is_empty() {
                    None
                } else {
                    Some(state.editing_note_text.as_str())
                };
                let rt = tokio::runtime::Handle::current();
                if let Err(e) = rt.block_on(store.update_note_async(id, note)) {
                    eprintln!("warning: failed to save note: {e}");
                }
            }
            state.editing_note_id = None;
            state.editing_note_text = String::new();
            return refresh_bookmarks(state);
        }

        Message::CancelEditNote => {
            state.editing_note_id = None;
            state.editing_note_text = String::new();
        }

        Message::DeleteBookmark(id) => {
            if let Some(store) = &state.bookmark_store {
                let rt = tokio::runtime::Handle::current();
                if let Err(e) = rt.block_on(store.remove_async(id)) {
                    eprintln!("warning: failed to delete bookmark: {e}");
                }
            }
            return refresh_bookmarks(state);
        }

        Message::ExportBookmarks => {
            if let (Some(path), Some(store)) = (&state.file_path, &state.bookmark_store) {
                match store.export_markdown(path) {
                    Ok(md) => {
                        // Save to file next to the document.
                        let export_path = path.with_extension("bookmarks.md");
                        if let Err(e) = std::fs::write(&export_path, &md) {
                            eprintln!("warning: failed to export bookmarks: {e}");
                        } else {
                            eprintln!("Bookmarks exported to {}", export_path.display());
                        }
                    }
                    Err(e) => eprintln!("warning: failed to export bookmarks: {e}"),
                }
            }
        }

        // In-document search
        Message::ToggleSearchBar => {
            if state.screen == Screen::Reader
                && matches!(
                    state.document,
                    Some(OpenDocument::Pdf(_)) | Some(OpenDocument::Epub(_))
                )
            {
                invalidate_continuous_layout(state);
                state.show_search_bar = !state.show_search_bar;
                if !state.show_search_bar {
                    let previous_highlights = current_page_search_highlights(state);
                    // Clear results when closing.
                    state.search_query.clear();
                    state.search_results.clear();
                    state.search_current = 0;
                    state.search_query_generation = state.search_query_generation.wrapping_add(1);
                    if uses_paginated_raster_layout(state) {
                        return refresh_content(state);
                    }
                    return Task::batch([
                        refresh_pdf_search_highlights_if_changed(state, &previous_highlights),
                        scroll_to_current_page(state),
                    ]);
                } else {
                    return Task::batch([
                        iced::widget::operation::focus(search_input_id()),
                        reader_layout_changed_task(state),
                    ]);
                }
            }
        }

        Message::SearchQueryChanged(query) => {
            let previous_highlights = current_page_search_highlights(state);
            state.search_query = query;
            state.search_query_generation = state.search_query_generation.wrapping_add(1);
            state.search_results.clear();
            state.search_current = 0;
            let render_task = refresh_pdf_search_highlights_if_changed(state, &previous_highlights);
            if !state.search_query.is_empty() {
                return Task::batch([render_task, perform_search(state)]);
            }
            return render_task;
        }

        Message::SearchTextExtracted {
            tab_id,
            document_generation,
            text,
        } => {
            if state.active_tab_id == Some(tab_id)
                && document_generation == state.search_document_generation
            {
                state.search_loading = false;
                state.search_text = Some(text);
                if !state.search_query.is_empty() {
                    return perform_search(state);
                }
            }
        }

        Message::SearchPerformed {
            tab_id,
            document_generation,
            query_generation,
            results,
        } => {
            if state.active_tab_id == Some(tab_id)
                && document_generation == state.search_document_generation
                && query_generation == state.search_query_generation
            {
                let previous_highlights = current_page_search_highlights(state);
                state.search_results = results;
                state.search_current = 0;
                // Navigate to first result if any.
                return navigate_to_current_search_result(state, &previous_highlights);
            }
        }

        Message::SearchNext => {
            if !state.search_results.is_empty() {
                let previous_highlights = current_page_search_highlights(state);
                state.search_current = (state.search_current + 1) % state.search_results.len();
                return navigate_to_current_search_result(state, &previous_highlights);
            }
        }

        Message::SearchPrev => {
            if !state.search_results.is_empty() {
                let previous_highlights = current_page_search_highlights(state);
                state.search_current = if state.search_current == 0 {
                    state.search_results.len() - 1
                } else {
                    state.search_current - 1
                };
                return navigate_to_current_search_result(state, &previous_highlights);
            }
        }

        Message::CloseSearch => {
            invalidate_continuous_layout(state);
            let previous_highlights = current_page_search_highlights(state);
            state.show_search_bar = false;
            state.search_query.clear();
            state.search_results.clear();
            state.search_current = 0;
            state.search_query_generation = state.search_query_generation.wrapping_add(1);
            if uses_paginated_raster_layout(state) {
                return refresh_content(state);
            }
            return Task::batch([
                refresh_pdf_search_highlights_if_changed(state, &previous_highlights),
                scroll_to_current_page(state),
            ]);
        }

        Message::PageRendered {
            tab_id,
            generation,
            key,
            result,
        } => {
            if state.active_tab_id == Some(tab_id) && generation == state.render_generation {
                match result {
                    Ok(page) => {
                        let is_visible = paginated_raster_pages(state).contains(&key.page);
                        cache_rendered_page(state, key, page);
                        let spread_changed = is_visible && show_cached_paginated_spread(state);
                        state.error = None;
                        if spread_changed {
                            return prefetch_next_paginated_spread(state);
                        }
                    }
                    Err(error) => {
                        state.rendered_page = None;
                        state.rendered_page_index = None;
                        state.rendered_page_handle = None;
                        state.rendered_facing_page = None;
                        state.rendered_facing_page_handle = None;
                        state.error = Some(format!("Failed to render page: {error}"));
                    }
                }
            }
        }

        Message::ContinuousPageRendered {
            tab_id,
            request,
            page,
            result,
        } => {
            if state.active_tab_id != Some(tab_id) {
                if let Some(tab) = state.tabs.iter_mut().find(|tab| tab.id == tab_id)
                    && tab.continuous_pending.get(&page) == Some(&request)
                {
                    tab.continuous_pending.remove(&page);
                    if request.generation == tab.render_generation
                        && let (Some(slot), Ok(rendered)) =
                            (tab.continuous_pages.get_mut(page), result)
                    {
                        *slot = Some(rendered);
                    }
                }
                return reconcile_continuous_rasters(state);
            }
            if state.active_tab_id == Some(tab_id) {
                if state.continuous_pending.get(&page) != Some(&request) {
                    return Task::none();
                }
                state.continuous_pending.remove(&page);
                if page >= state.continuous_pages.len() {
                    return reconcile_continuous_rasters(state);
                }
                match (request.generation == state.render_generation, result) {
                    (true, Ok(rendered)) => {
                        state.continuous_pages[page] = Some(rendered);
                        if page == state.current_page {
                            return Task::batch([
                                reconcile_continuous_rasters(state),
                                scroll_to_current_page(state),
                            ]);
                        }
                    }
                    (true, Err(error)) => {
                        if page == state.current_page {
                            state.error = Some(format!("Failed to render page: {error}"));
                            return Task::none();
                        }
                        state.continuous_visible.remove(&page);
                        return reconcile_continuous_rasters(state);
                    }
                    (false, _) => {}
                }
                return reconcile_continuous_rasters(state);
            }
        }

        Message::RenderContinuousPage { tab_id, page } => {
            if state.reading_mode != ReadingMode::Continuous
                || state.active_tab_id != Some(tab_id)
                || page >= state.continuous_pages.len()
                || state.continuous_pages[page].is_some()
                || !state.continuous_pending.contains_key(&page)
            {
                return Task::none();
            }
            let Some(request) = state.continuous_pending.get(&page).copied() else {
                return Task::none();
            };
            let scale = raster_render_scale(state, state.zoom.scale());
            match &state.document {
                Some(OpenDocument::Pdf(doc)) => {
                    let doc = Arc::clone(doc);
                    let highlights = search_highlights_for_page(state, page);
                    return render_continuous_page_task(tab_id, request, page, move || {
                        doc.render_page_with_highlights(page, scale, &highlights)
                    });
                }
                Some(OpenDocument::Cbz(doc)) => {
                    let doc = Arc::clone(doc);
                    return render_continuous_page_task(tab_id, request, page, move || {
                        doc.render_page(page, scale)
                    });
                }
                _ => {}
            }
        }

        Message::KeyPressed(event) => {
            return handle_key_event(state, event);
        }

        Message::WindowEvent(id, event) => {
            state.window_id = Some(id);
            let mut application_icon = Task::none();
            match event {
                window::Event::Opened { position, size } => {
                    state.window_size = size;
                    state.window_position = position;
                    let generation = state.window_scale_generation;
                    application_icon = Task::batch([
                        crate::application_icon_task(id),
                        window::scale_factor(id).map(move |scale_factor| {
                            Message::WindowScaleFactorLoaded {
                                generation,
                                scale_factor,
                            }
                        }),
                    ]);
                    if let Some((saved_size, saved_position)) = state.saved_window_geometry {
                        return Task::batch([
                            application_icon,
                            window::resize(id, saved_size),
                            window::move_to(id, saved_position),
                        ]);
                    }
                }
                window::Event::Resized(size) => {
                    state.window_size = size;
                    invalidate_continuous_layout(state);
                }
                window::Event::Rescaled(scale_factor) => {
                    state.window_scale_generation = state.window_scale_generation.wrapping_add(1);
                    return update_window_scale_factor(state, scale_factor);
                }
                window::Event::Moved(position) => state.window_position = Some(position),
                window::Event::CloseRequested => {
                    state.close_after_geometry_save = Some(id);
                    state.window_geometry_generation =
                        state.window_geometry_generation.wrapping_add(1);
                    state.window_geometry_dirty = true;
                    return persist_window_geometry(state);
                }
                _ => return Task::none(),
            }
            state.window_geometry_generation = state.window_geometry_generation.wrapping_add(1);
            state.window_geometry_dirty = true;
            let generation = state.window_geometry_generation;
            let persist = Task::perform(
                async move { tokio::time::sleep(std::time::Duration::from_millis(350)).await },
                move |_| Message::PersistWindowGeometry(generation),
            );
            let content = reader_layout_changed_task(state);
            return Task::batch([application_icon, persist, content]);
        }

        Message::WindowScaleFactorLoaded {
            generation,
            scale_factor,
        } if generation == state.window_scale_generation => {
            return update_window_scale_factor(state, scale_factor);
        }

        Message::WindowScaleFactorLoaded { .. } => {}

        Message::PersistWindowGeometry(generation) => {
            if generation != state.window_geometry_generation {
                return Task::none();
            }
            return persist_window_geometry(state);
        }

        Message::WindowGeometryPersisted => {
            state.window_geometry_saving = false;
            if state.window_geometry_dirty {
                return persist_window_geometry(state);
            }
            if let Some(id) = state.close_after_geometry_save.take() {
                return window::close(id);
            }
        }
    }

    Task::none()
}
