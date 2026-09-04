use super::*;

fn cancel_add_books_discovery(state: &mut State) {
    if let Some(cancellation) = state.add_books_cancellation.take() {
        cancellation.cancel();
    }
    state.add_books_progress = None;
    state.add_books_discovering = false;
}

fn update_book_import_progress(state: &mut State) {
    state.library_activity_progress = if state.book_import_copy {
        (state.book_import_prepared + state.book_import_completed) as f32
            / (state.book_import_total.max(1) * 2) as f32
    } else {
        state.book_import_completed as f32 / state.book_import_total.max(1) as f32
    };
}

pub(super) fn record_book_import_report(state: &mut State, report: ImportReport) {
    state.book_import_completed += report.succeeded + report.failed;
    update_book_import_progress(state);
    for imported in report.imported() {
        if state.file_path.as_deref().is_some_and(|path| {
            opened_content_matches_import(path, state.document_content_hash.as_deref(), imported)
        }) {
            state.book_id = Some(imported.book_id());
        }
        for tab in &mut state.tabs {
            if opened_content_matches_import(
                tab.session.locator.path(),
                tab.content_hash.as_deref(),
                imported,
            ) {
                tab.session.book_id = Some(imported.book_id());
            }
        }
    }
    state.book_import_report.merge(report);
}

fn opened_content_matches_import(
    path: &Path,
    content_hash: Option<&str>,
    imported: &ImportedBook,
) -> bool {
    content_hash == Some(imported.content_hash())
        && (path == imported.source_path() || path == imported.library_path())
}

fn finish_book_import(state: &mut State) -> Task<Message> {
    state.adding_books = false;
    state.pending_book_imports.clear();
    state.prepared_book_imports.clear();
    state.book_import_preparing = 0;
    state.book_import_next_commit = 0;
    state.book_import_committing = false;
    state.book_import_cancellation = None;
    let report = std::mem::take(&mut state.book_import_report);
    state.book_import_total = 0;
    state.book_import_prepared = 0;
    state.book_import_completed = 0;
    let error = import_report_error(&report, &state.i18n);
    let refresh = reset_library(state);
    if let Some(error) = error {
        state.library_error = Some(error);
    }
    Task::batch([refresh, continue_close_after_durable_mutations(state)])
}

fn continue_book_import(state: &mut State) -> Task<Message> {
    if !state.adding_books {
        return Task::none();
    }
    let Some(library) = state.library.clone() else {
        return finish_book_import(state);
    };
    let Some(cancellation) = state.book_import_cancellation.clone() else {
        return finish_book_import(state);
    };

    if cancellation.is_cancelled() {
        state.pending_book_imports.clear();
        state.prepared_book_imports.clear();
        if state.book_import_preparing == 0 && !state.book_import_committing {
            return finish_book_import(state);
        }
        return Task::none();
    }
    let generation = state.book_import_generation;

    if !state.book_import_copy {
        if state.book_import_committing {
            return Task::none();
        }
        let Some((_index, candidate)) = state.pending_book_imports.pop_front() else {
            return finish_book_import(state);
        };
        state.book_import_committing = true;
        return Task::perform(
            async move {
                library
                    .link_discovered_file_cancellable(candidate, cancellation)
                    .await
            },
            move |completion| Message::BookAddedToBatch {
                generation,
                completion,
            },
        );
    }

    let mut tasks = Vec::new();
    if !state.book_import_committing {
        while let Some(prepared) = state
            .prepared_book_imports
            .remove(&state.book_import_next_commit)
        {
            state.book_import_next_commit += 1;
            match prepared {
                Err(failure) => {
                    record_book_import_report(state, ImportReport::from_failure(failure))
                }
                Ok((_path, prepared)) => {
                    state.book_import_committing = true;
                    let commit_library = library.clone();
                    let commit_cancellation = cancellation.clone();
                    tasks.push(Task::perform(
                        async move {
                            commit_library
                                .commit_prepared_managed_file_cancellable(
                                    &prepared,
                                    commit_cancellation,
                                )
                                .await
                        },
                        move |completion| Message::BookAddedToBatch {
                            generation,
                            completion,
                        },
                    ));
                    break;
                }
            }
        }
    }

    while state.book_import_preparing
        + state.prepared_book_imports.len()
        + usize::from(state.book_import_committing)
        < MANAGED_IMPORT_PREPARATION_CONCURRENCY
    {
        let Some((index, candidate)) = state.pending_book_imports.pop_front() else {
            break;
        };
        let library = library.clone();
        let path = candidate.path.clone();
        let prepare_cancellation = cancellation.clone();
        state.book_import_preparing += 1;
        tasks.push(Task::perform(
            async move {
                match library
                    .prepare_discovered_managed_file_cancellable(candidate, prepare_cancellation)
                    .await
                {
                    Ok(prepared) => Ok((path, Arc::new(prepared))),
                    Err(error) => Err(ImportFailure::new(path, format!("{error:#}"))),
                }
            },
            move |result| Message::ManagedBookPrepared {
                generation,
                index,
                result,
            },
        ));
    }

    if state.book_import_completed == state.book_import_total
        && !state.book_import_committing
        && state.book_import_preparing == 0
    {
        tasks.push(finish_book_import(state));
    }

    Task::batch(tasks)
}

pub fn update(state: &mut State, message: Message) -> Task<Message> {
    if state.close_after_geometry_save.is_some()
        && matches!(
            &message,
            Message::AddSelectedBooks
                | Message::CancelBookImport
                | Message::RelinkBookSelected { path: Some(_), .. }
                | Message::RemoveBook(_)
                | Message::ConfirmManagedLibraryMove
                | Message::ToggleBookmark
                | Message::SaveNote
                | Message::DeleteBookmark(_)
        )
    {
        return Task::none();
    }
    match message {
        Message::Initialized(Ok(initialized)) => {
            let InitializedState {
                store,
                window_geometry: geometry,
                language_preference,
                managed_books_dir,
                add_book_behavior,
                reader_defaults,
            } = initialized;
            state.i18n.set_preference(language_preference);
            let pool = store.pool().clone();
            let backfill_store = store.clone();
            let backfill_task = Task::perform(
                async move {
                    backfill_store
                        .backfill_missing_fingerprints()
                        .await
                        .map_err(|error| format!("{error:#}"))
                },
                Message::FingerprintBackfillFinished,
            );
            state.library = Some(Library::new(pool.clone(), managed_books_dir));
            state.bookmark_store = Some(BookmarkStore::new(pool));
            state.reading_state_saves = Some(start_reading_state_writer(store.clone()));
            state.reading_state = Some(store);
            state.add_book_behavior = add_book_behavior;
            state.reader_defaults = reader_defaults;
            state.storage_initializing = false;
            if state.close_after_geometry_save.is_some() {
                state.window_geometry_dirty = true;
                return persist_window_geometry(state);
            }
            state.fingerprint_backfill_running = true;
            let geometry = (!state.performance.is_automated())
                .then_some(geometry)
                .flatten();
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
                return Task::batch([
                    geometry_task,
                    backfill_task,
                    Task::done(Message::FileSelected(Some(pending))),
                ]);
            }
            return Task::batch([geometry_task, backfill_task, reset_library(state)]);
        }

        Message::Initialized(Err(error)) => {
            eprintln!("warning: failed to open reading state database: {error}");
            state.storage_initializing = false;
            state.library_loading = false;
            state.storage_error = Some(AppError::Storage(error));
            if state.close_after_geometry_save.is_some() {
                return continue_close_after_durable_mutations(state);
            }
            if let Some(pending) = state.pending_open.take() {
                return Task::done(Message::FileSelected(Some(pending)));
            }
        }

        Message::FingerprintBackfillFinished(Err(error)) => {
            state.fingerprint_backfill_running = false;
            eprintln!("warning: failed to backfill legacy book fingerprints: {error}");
            return continue_close_after_durable_mutations(state);
        }

        Message::FingerprintBackfillFinished(Ok(())) => {
            state.fingerprint_backfill_running = false;
            return continue_close_after_durable_mutations(state);
        }

        Message::OpenFile => {
            let ebooks = state.i18n.text("ebooks");
            let open_file = state.i18n.text("open-file");
            return Task::perform(
                async move {
                    let file = rfd::AsyncFileDialog::new()
                        .add_filter(&ebooks, &["pdf", "epub", "cbz"])
                        .add_filter("PDF", &["pdf"])
                        .add_filter("EPUB", &["epub"])
                        .add_filter("CBZ", &["cbz"])
                        .set_title(&open_file)
                        .pick_file()
                        .await;

                    file.map(|f| f.path().to_path_buf())
                },
                Message::FileSelected,
            );
        }

        Message::FileSelected(Some(path)) => {
            if state.storage_initializing {
                state.pending_open = Some(path);
                return Task::none();
            }
            return open_document(state, path, None);
        }

        Message::FileSelected(None) => {}

        Message::DocumentOpened {
            generation,
            path,
            book_id,
            result,
        } => {
            if generation != state.document_open_generation {
                state.pending_document_permits.remove(&generation);
                return Task::none();
            }
            state.document_opening = false;
            state.document_open_notice_visible = false;
            state.document_open_preview = None;
            match result {
                Ok((document, content_hash)) => {
                    return finish_open_document_with_hash(
                        state,
                        path,
                        book_id,
                        document,
                        Some(content_hash),
                    );
                }
                Err(error) => {
                    state.pending_document_permits.remove(&generation);
                    let performance_task = perf::fail(state, &error.diagnostic());
                    state.screen = Screen::Reader;
                    state.open_error = Some(error);
                    return performance_task;
                }
            }
        }

        Message::ShowDocumentOpenNotice(generation)
            if generation == state.document_open_generation && state.document_opening =>
        {
            state.document_open_notice_visible = true;
            state.screen = Screen::Reader;
        }

        Message::ShowDocumentOpenNotice(_) => {}

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
            state.reader_overrides.reading_mode = true;
            invalidate_continuous_layout(state);
            state.reading_mode = match state.reading_mode {
                ReadingMode::Paginated => ReadingMode::Continuous,
                ReadingMode::Continuous => ReadingMode::Paginated,
            };
            state.continuous_pages.clear();
            state.continuous_visible.clear();
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
                let is_epub = matches!(state.document, Some(OpenDocument::Epub(_)));
                let index = continuous_measurement_index(state, tab_id, activation);
                return iced::advanced::widget::operate(ContinuousItemOperation::resolve(
                    index,
                    continuous_scroll_id(tab_id, activation),
                    offset,
                ))
                .map(move |(page, epub_offset, _, _)| {
                    Message::ContinuousItemResolved {
                        tab_id,
                        activation,
                        page,
                        epub_offset: is_epub.then_some(epub_offset),
                    }
                });
            }
        }

        Message::ContinuousItemResolved {
            tab_id,
            activation,
            page,
            epub_offset,
        } => {
            if state.reading_mode == ReadingMode::Continuous
                && state.active_tab_id == Some(tab_id)
                && state.continuous_activation == activation
                && page < state.total_pages
                && (page != state.current_page
                    || epub_offset.is_some_and(|offset| offset != state.epub_offset))
            {
                state.current_page = page;
                state.epub_page = 0;
                state.epub_offset = epub_offset.unwrap_or(0);
                state.page_input = (page + 1).to_string();
                save_reading_state(state);
                update_bookmark_status(state);
                return Task::batch([
                    reconcile_continuous_rasters(state),
                    load_epub_images_task(state),
                ]);
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
                state.reader_overrides.pdf_zoom = true;
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
                state.reader_overrides.pdf_zoom = true;
                let new_scale = zoom_step_scale(state, -0.25);
                state.zoom = ZoomMode::Manual(new_scale);
                invalidate_continuous_rasters(state);
                save_reading_state(state);
                return refresh_content(state);
            }
        }

        Message::SetZoomFitWidth => {
            state.reader_overrides.pdf_zoom = true;
            state.zoom = ZoomMode::FitWidth;
            invalidate_continuous_rasters(state);
            save_reading_state(state);
            return refresh_content(state);
        }

        Message::SetZoomFitPage => {
            state.reader_overrides.pdf_zoom = true;
            state.zoom = ZoomMode::FitPage;
            invalidate_continuous_rasters(state);
            save_reading_state(state);
            return refresh_content(state);
        }

        Message::FontSizeUp => {
            state.reader_overrides.epub_font_size = true;
            perf::begin_relayout(state);
            state.font_size = (state.font_size + 2.0).min(48.0);
            invalidate_continuous_layout(state);
            if uses_paginated_epub_layout(state) {
                return refresh_content(state);
            }
            return scroll_to_current_page(state);
        }

        Message::FontSizeDown => {
            state.reader_overrides.epub_font_size = true;
            perf::begin_relayout(state);
            state.font_size = (state.font_size - 2.0).max(8.0);
            invalidate_continuous_layout(state);
            if uses_paginated_epub_layout(state) {
                return refresh_content(state);
            }
            return scroll_to_current_page(state);
        }

        Message::CycleTheme => {
            state.reader_overrides.theme = true;
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
            if state.moving_library {
                return Task::none();
            }
            invalidate_continuous_layout(state);
            state.screen = Screen::Library;
            state.show_reader_settings = false;
            state.show_reader_more = false;
            return Task::done(Message::RefreshLibrary);
        }

        Message::ShowSettings => {
            state.screen = Screen::Settings;
            state.book_menu = None;
            state.pending_remove_book = None;
            state.add_books_open = false;
            state.add_books_source = None;
        }

        Message::RefreshLibrary => {
            return reset_library(state);
        }

        Message::LoadMoreLibrary => {
            if state.library_has_more && !state.library_loading {
                return load_library_page(state, true);
            }
        }

        Message::LibraryLoaded {
            generation,
            offset,
            next_offset,
            mut page,
        } => {
            if generation != state.library_generation || offset != state.library_offset {
                return Task::none();
            }
            let covers = page
                .books
                .iter_mut()
                .filter_map(|book| book.cover.take().map(|cover| (book.id, cover)))
                .collect();
            if offset > 0 {
                state.library_books.extend(page.books);
            } else {
                state.library_books = page.books;
                state.library_cover_handles.clear();
            }
            state.library_offset = next_offset;
            state.library_has_more = page.has_more;
            state.library_loading = false;
            if offset == 0 {
                state.library_activity_progress = 1.0;
            }
            return decode_library_covers_task(generation, offset, covers);
        }

        Message::LibraryCoversLoaded {
            generation,
            offset,
            cover_handles,
        } => {
            if generation == state.library_generation && offset < state.library_offset {
                state.library_cover_handles.extend(cover_handles);
            }
        }

        Message::OpenAddBooks => {
            if state.library.is_some() && !state.adding_books && !state.moving_library {
                cancel_add_books_discovery(state);
                state.book_menu = None;
                state.pending_remove_book = None;
                state.add_books_source = None;
                state.add_books_generation = state.add_books_generation.wrapping_add(1);
                state.staged_imports.clear();
                state.add_books_review_search.clear();
                state.add_books_review_rows.clear();
                state.add_books_review_offset = 0.0;
                state.import_discovery_failures.clear();
                state.add_books_copy = None;
                state.add_books_open = true;
            }
        }

        Message::CancelAddBooks => {
            cancel_add_books_discovery(state);
            state.add_books_open = false;
            state.add_books_source = None;
            state.add_books_generation = state.add_books_generation.wrapping_add(1);
            state.staged_imports.clear();
            state.add_books_review_search.clear();
            state.add_books_review_rows.clear();
            state.add_books_review_offset = 0.0;
            state.import_discovery_failures.clear();
            state.add_books_copy = None;
        }

        Message::ChooseBookFiles => {
            if !state.add_books_open || state.library.is_none() {
                return Task::none();
            }
            cancel_add_books_discovery(state);
            state.add_books_generation = state.add_books_generation.wrapping_add(1);
            let generation = state.add_books_generation;
            let ebooks = state.i18n.text("ebooks");
            let choose_files = state.i18n.text("choose-book-files");
            return Task::perform(
                async move {
                    rfd::AsyncFileDialog::new()
                        .add_filter(&ebooks, &["pdf", "epub", "cbz"])
                        .set_title(&choose_files)
                        .pick_files()
                        .await
                        .unwrap_or_default()
                        .into_iter()
                        .map(|file| file.path().to_path_buf())
                        .collect()
                },
                move |paths| Message::AddBookFilesSelected { generation, paths },
            );
        }

        Message::ChooseBookFolder => {
            if !state.add_books_open || state.library.is_none() {
                return Task::none();
            }
            cancel_add_books_discovery(state);
            state.add_books_generation = state.add_books_generation.wrapping_add(1);
            let generation = state.add_books_generation;
            let choose_folder = state.i18n.text("choose-book-folder");
            return Task::perform(
                async move {
                    rfd::AsyncFileDialog::new()
                        .set_title(&choose_folder)
                        .pick_folder()
                        .await
                        .map(|folder| folder.path().to_path_buf())
                },
                move |path| Message::AddBookFolderSelected { generation, path },
            );
        }

        Message::AddBookFilesSelected { generation, paths } => {
            let Some(lib) = state.library.clone() else {
                return Task::none();
            };
            if !state.add_books_open || generation != state.add_books_generation || paths.is_empty()
            {
                return Task::none();
            }
            state.add_books_source = Some(AddBooksSource::Files(paths.clone()));
            state.add_books_discovering = true;
            state.library_activity_progress = 0.0;
            state.library_activity_opacity = 1.0;
            state.staged_imports.clear();
            state.import_discovery_failures.clear();
            let cancellation = ImportCancellation::default();
            let progress = ImportDiscoveryProgress::default();
            state.add_books_cancellation = Some(cancellation.clone());
            state.add_books_progress = Some(progress.clone());
            return Task::perform(
                async move {
                    lib.discover_files_with_progress(paths, cancellation, progress)
                        .await
                },
                move |discovery| Message::BooksDiscovered {
                    generation,
                    discovery,
                },
            );
        }

        Message::AddBookFolderSelected { generation, path } => {
            let (Some(lib), Some(path)) = (state.library.clone(), path) else {
                return Task::none();
            };
            if !state.add_books_open || generation != state.add_books_generation {
                return Task::none();
            }
            state.add_books_source = Some(AddBooksSource::Folder(path.clone()));
            state.add_books_discovering = true;
            state.library_activity_progress = 0.0;
            state.library_activity_opacity = 1.0;
            state.staged_imports.clear();
            state.import_discovery_failures.clear();
            let cancellation = ImportCancellation::default();
            let progress = ImportDiscoveryProgress::default();
            state.add_books_cancellation = Some(cancellation.clone());
            state.add_books_progress = Some(progress.clone());
            return Task::perform(
                async move {
                    lib.discover_directory_with_progress(path, cancellation, progress)
                        .await
                },
                move |discovery| Message::BooksDiscovered {
                    generation,
                    discovery,
                },
            );
        }

        Message::BooksDiscovered {
            generation,
            discovery,
        } => {
            if !state.add_books_open || generation != state.add_books_generation {
                return Task::none();
            }
            state.add_books_discovering = false;
            state.add_books_cancellation = None;
            state.add_books_progress = None;
            state.library_activity_progress = 1.0;
            state.staged_imports = discovery
                .candidates
                .into_iter()
                .map(|candidate| StagedImport {
                    selected: candidate.duplicate.is_none(),
                    candidate,
                })
                .collect();
            state.add_books_review_search.clear();
            rebuild_add_books_review_rows(state);
            state.import_discovery_failures = discovery.failures;
            state.add_books_copy = match state.add_book_behavior {
                AddBookBehavior::Ask => None,
                AddBookBehavior::Copy => Some(true),
                AddBookBehavior::CurrentLocation => Some(false),
            };
        }

        Message::AddBooksReviewSearchChanged(query) => {
            if state.add_books_open && !state.add_books_discovering {
                state.add_books_review_search = query;
                rebuild_add_books_review_rows(state);
                return iced::widget::operation::snap_to(
                    WidgetId::new("add-books-review-scroll"),
                    iced::widget::operation::RelativeOffset::START,
                );
            }
        }

        Message::AddBooksReviewScrolled {
            generation,
            revision,
            offset,
            viewport_height,
        } => {
            if state.add_books_open
                && !state.add_books_discovering
                && generation == state.add_books_generation
                && revision == state.add_books_review_revision
            {
                state.add_books_review_offset = offset.max(0.0);
                state.add_books_review_viewport_height = viewport_height.max(1.0);
            }
        }

        Message::ToggleStagedBook(index, selected) => {
            if state.add_books_open
                && let Some(staged) = state.staged_imports.get_mut(index)
            {
                staged.selected = selected;
            }
        }

        Message::SelectAllStagedBooks(selected) => {
            if state.add_books_open {
                for staged in &mut state.staged_imports {
                    if staged.candidate.duplicate.is_none() {
                        staged.selected = selected;
                    }
                }
            }
        }

        Message::SelectAddBooksStorage(copy) => {
            if state.add_books_open && state.add_books_source.is_some() {
                state.add_books_copy = Some(copy);
            }
        }

        Message::ClearAddBooksSelection => {
            if state.add_books_open {
                cancel_add_books_discovery(state);
                state.add_books_source = None;
                state.add_books_generation = state.add_books_generation.wrapping_add(1);
                state.staged_imports.clear();
                state.add_books_review_search.clear();
                state.add_books_review_rows.clear();
                state.add_books_review_offset = 0.0;
                state.import_discovery_failures.clear();
                state.add_books_copy = None;
            }
        }

        Message::ChangeAddBooksStorage => {
            if state.add_books_open && state.add_books_source.is_some() {
                state.add_books_copy = None;
            }
        }

        Message::AddSelectedBooks => {
            if state.adding_books {
                return Task::none();
            }
            let Some(copy) = state.add_books_copy else {
                return Task::none();
            };
            if state.library.is_none() {
                return Task::none();
            }
            let candidates: Vec<_> = state
                .staged_imports
                .iter()
                .filter(|staged| staged.selected)
                .map(|staged| staged.candidate.clone())
                .collect();
            if candidates.is_empty() {
                return Task::none();
            }
            state.add_books_open = false;
            state.add_books_source = None;
            state.staged_imports.clear();
            state.add_books_review_search.clear();
            state.add_books_review_rows.clear();
            state.add_books_review_offset = 0.0;
            state.import_discovery_failures.clear();
            state.add_books_copy = None;
            state.adding_books = true;
            state.pending_book_imports = candidates.into_iter().enumerate().collect();
            state.prepared_book_imports.clear();
            state.book_import_preparing = 0;
            state.book_import_next_commit = 0;
            state.book_import_committing = false;
            state.book_import_generation = state.book_import_generation.wrapping_add(1);
            state.book_import_cancellation = Some(ImportCancellation::default());
            state.book_import_copy = copy;
            state.book_import_prepared = 0;
            state.book_import_completed = 0;
            state.book_import_total = state.pending_book_imports.len();
            state.book_import_report = ImportReport::default();
            state.library_activity_progress = 0.0;
            state.library_activity_opacity = 1.0;
            state.library_error = None;
            return continue_book_import(state);
        }

        Message::CancelBookImport => {
            if let Some(cancellation) = &state.book_import_cancellation {
                cancellation.cancel();
                state.pending_book_imports.clear();
                state.prepared_book_imports.clear();
                return continue_book_import(state);
            }
        }

        Message::ManagedBookPrepared {
            generation,
            index,
            result,
        } if generation == state.book_import_generation && state.adding_books => {
            state.book_import_preparing = state.book_import_preparing.saturating_sub(1);
            if state
                .book_import_cancellation
                .as_ref()
                .is_some_and(ImportCancellation::is_cancelled)
            {
                return continue_book_import(state);
            }
            state.book_import_prepared += 1;
            update_book_import_progress(state);
            state.prepared_book_imports.insert(index, result);
            return continue_book_import(state);
        }

        Message::ManagedBookPrepared { .. } => {}

        Message::BookAddedToBatch {
            generation,
            completion,
        } if generation == state.book_import_generation && state.adding_books => {
            state.book_import_committing = false;
            match completion {
                ImportCompletion::Cancelled => {}
                ImportCompletion::Completed(result) => match result {
                    Ok(imported) => {
                        record_book_import_report(state, ImportReport::from_imported(imported))
                    }
                    Err(failure) => {
                        record_book_import_report(state, ImportReport::from_failure(failure))
                    }
                },
            }
            return continue_book_import(state);
        }

        Message::BookAddedToBatch { .. } => {}

        Message::OpenLibraryBook(book_id, file_path) => {
            if state.moving_library {
                return Task::none();
            }
            state.book_menu = None;
            state.pending_remove_book = None;
            let path = shosai_core::path_from_key(&file_path);
            if !path.exists() {
                state.screen = Screen::Reader;
                state.open_error = Some(AppError::MissingBook);
                state.missing_book_id = Some(book_id);
                return Task::none();
            }
            return open_document(state, path, Some(book_id));
        }

        Message::LocateBook(book_id) => {
            if state.library.is_none()
                || state.removing_book == Some(book_id)
                || state.relinking_book.is_some()
            {
                return Task::none();
            }
            state.relink_generation = state.relink_generation.wrapping_add(1);
            let generation = state.relink_generation;
            let ebooks = state.i18n.text("ebooks");
            let locate_book = state.i18n.text("locate-book-dialog");
            return Task::perform(
                async move {
                    let file = rfd::AsyncFileDialog::new()
                        .add_filter(&ebooks, &["pdf", "epub", "cbz"])
                        .set_title(&locate_book)
                        .pick_file()
                        .await;
                    file.map(|file| file.path().to_path_buf())
                },
                move |path| Message::RelinkBookSelected {
                    generation,
                    book_id,
                    path,
                },
            );
        }

        Message::RelinkBookSelected {
            generation,
            book_id,
            path: Some(path),
        } => {
            if generation != state.relink_generation {
                return Task::none();
            }
            let Some(lib) = state.library.clone() else {
                return Task::none();
            };
            state.relinking_book = Some((generation, book_id));
            return Task::perform(
                async move {
                    lib.relink(book_id, &path)
                        .await
                        .map_err(|error| format!("{error:#}"))
                },
                move |result| Message::BookRelinked { generation, result },
            );
        }

        Message::RelinkBookSelected { .. } => {}

        Message::BookRelinked { generation, result }
            if state
                .relinking_book
                .is_some_and(|(active, _)| active == generation) =>
        {
            state.relinking_book = None;
            match result {
                Ok(book) => {
                    state.open_error = None;
                    state.missing_book_id = None;
                    if state.close_after_geometry_save.is_some() {
                        return Task::batch([
                            reset_library(state),
                            continue_close_after_durable_mutations(state),
                        ]);
                    }
                    return Task::batch([
                        reset_library(state),
                        Task::done(Message::OpenLibraryBook(book.id, book.file_path)),
                    ]);
                }
                Err(error) => state.open_error = Some(AppError::Library(error)),
            }
            return continue_close_after_durable_mutations(state);
        }

        Message::BookRelinked { .. } => {}

        Message::ToggleBookMenu(id) => {
            if state.removing_book.is_none() && state.pending_remove_book.is_none() {
                state.book_menu = (state.book_menu != Some(id)).then_some(id);
            }
        }

        Message::CloseBookMenu => {
            state.book_menu = None;
        }

        Message::RequestRemoveBook(id) => {
            if state.removing_book.is_none()
                && state.relinking_book.is_none()
                && !state.moving_library
            {
                state.book_menu = None;
                state.pending_remove_book = Some(id);
                state.library_error = None;
            }
        }

        Message::CancelRemoveBook => {
            state.pending_remove_book = None;
        }

        Message::RemoveBook(id) => {
            if state.moving_library
                || state.relinking_book.is_some()
                || state.removing_book.is_some()
                || (state.pending_remove_book != Some(id) && state.missing_book_id != Some(id))
            {
                return Task::none();
            }
            let Some(lib) = state.library.clone() else {
                return Task::none();
            };
            state.book_menu = None;
            state.pending_remove_book = None;
            state.removing_book = Some(id);
            state.library_error = None;
            let saves = state.reading_state_saves.clone();
            return Task::perform(
                async move {
                    if let Some(saves) = saves {
                        saves.flush().await.map_err(|error| error.to_string())?;
                    }
                    lib.remove(id).await.map_err(|error| format!("{error:#}"))
                },
                move |result| Message::BookRemoved { id, result },
            );
        }

        Message::BookRemoved { id, result } => {
            if state.removing_book == Some(id) {
                state.removing_book = None;
            }
            match result {
                Ok(()) => {
                    state.library_books.retain(|book| book.id != id);
                    state.library_cover_handles.remove(&id);
                    let mut detached_paths = BTreeSet::new();
                    let mut detached_saves = Vec::new();
                    if state.book_id == Some(id) {
                        if let Some(path) = &state.file_path {
                            detached_paths.insert(path.clone());
                            detached_saves.push(ReadingStateSave {
                                book_id: None,
                                path: path.clone(),
                                content_hash: state.document_content_hash.clone(),
                                reading: FileReadingState {
                                    page: state.current_page,
                                    location_offset: current_epub_offset(state),
                                    zoom: state.zoom.scale(),
                                },
                            });
                        }
                        state.book_id = None;
                        for bookmark in &mut state.bookmarks {
                            bookmark.book_id = None;
                        }
                    }
                    for tab in &mut state.tabs {
                        if tab.session.book_id == Some(id) {
                            let path = tab.session.locator.path().to_path_buf();
                            if detached_paths.insert(path.clone()) {
                                detached_saves.push(ReadingStateSave {
                                    book_id: None,
                                    path,
                                    content_hash: tab.content_hash.clone(),
                                    reading: FileReadingState {
                                        page: tab.session.location.page,
                                        location_offset: tab.session.location.offset,
                                        zoom: tab.session.preferences.pdf_zoom.scale(),
                                    },
                                });
                            }
                            tab.session.book_id = None;
                            for bookmark in &mut tab.bookmarks {
                                bookmark.book_id = None;
                            }
                        }
                    }
                    if let Some(saves) = &state.reading_state_saves {
                        for save in detached_saves {
                            if saves.send(ReadingStateWriterMessage::Save(save)).is_err() {
                                eprintln!("warning: reading state writer stopped unexpectedly");
                                break;
                            }
                        }
                    }
                    if state.missing_book_id == Some(id) {
                        state.missing_book_id = None;
                        state.open_error = None;
                        state.screen = Screen::Library;
                    }
                    return Task::batch([
                        reset_library(state),
                        continue_close_after_durable_mutations(state),
                    ]);
                }
                Err(error)
                    if state.screen == Screen::Reader && state.missing_book_id == Some(id) =>
                {
                    state.open_error = Some(AppError::Library(error));
                }
                Err(error) => {
                    state.library_error = Some(AppError::Library(error));
                }
            }
            return continue_close_after_durable_mutations(state);
        }

        Message::LibrarySearchChanged(query) => {
            state.library_search = query;
            state.library_generation = state.library_generation.wrapping_add(1);
            let generation = state.library_generation;
            state.library_loading = false;
            if !state.library_search_pending {
                state.library_activity_progress = 0.0;
            }
            state.library_search_pending = true;
            state.library_activity_opacity = 1.0;
            return Task::perform(
                async move {
                    tokio::time::sleep(SEARCH_DEBOUNCE).await;
                    generation
                },
                Message::LibrarySearchDebounced,
            );
        }

        Message::LibrarySearchDebounced(generation) => {
            if generation != state.library_generation {
                return Task::none();
            }
            state.library_search_pending = false;
            state.library_offset = 0;
            state.library_has_more = false;
            state.book_menu = None;
            state.pending_remove_book = None;
            state.library_error = None;
            return load_library_page(state, false);
        }

        Message::LibraryFilterChanged(filter) => {
            state.screen = Screen::Library;
            state.library_filter = filter;
            return reset_library(state);
        }

        Message::LibraryActivityTick => {
            if library_activity_active(state) {
                state.library_activity_opacity = 1.0;
            } else {
                state.library_activity_opacity =
                    (state.library_activity_opacity - LIBRARY_ACTIVITY_FADE_STEP).max(0.0);
            }
            if state.add_books_discovering {
                if let Some(progress) = &state.add_books_progress {
                    let progress = progress.snapshot();
                    state.library_activity_progress =
                        discovery_progress_value(state.library_activity_progress, progress);
                }
            } else if !state.adding_books && library_activity_active(state) {
                state.library_activity_progress =
                    (state.library_activity_progress + LIBRARY_ACTIVITY_STEP).min(1.0);
            }
        }

        Message::SelectLanguage(preference) => {
            let Some(saves) = &state.reading_state_saves else {
                return Task::none();
            };
            state.i18n.set_preference(preference);
            if saves
                .send(ReadingStateWriterMessage::Preference(
                    LANGUAGE_PREFERENCE_KEY.to_owned(),
                    preference.stored().to_owned(),
                ))
                .is_err()
            {
                eprintln!("warning: state writer stopped unexpectedly");
            }
        }

        Message::SelectAddBookBehavior(behavior) => {
            state.add_book_behavior = behavior;
            save_preference(state, ADD_BOOK_BEHAVIOR_KEY, behavior.stored());
        }

        Message::SelectDefaultReadingMode(mode) => {
            state.reader_defaults.reading_mode = mode;
            save_preference(state, DEFAULT_READING_MODE_KEY, mode.stored());
            let changes = apply_reader_defaults_to_open_tabs(state);
            return reader_defaults_changed_task(state, changes);
        }

        Message::SelectDefaultReaderTheme(theme) => {
            state.reader_defaults.theme = theme;
            save_preference(state, DEFAULT_READER_THEME_KEY, theme.stored());
            let changes = apply_reader_defaults_to_open_tabs(state);
            return reader_defaults_changed_task(state, changes);
        }

        Message::DefaultEpubFontSizeUp => {
            state.reader_defaults.epub_font_size =
                (state.reader_defaults.epub_font_size + 2.0).min(48.0);
            save_preference(
                state,
                DEFAULT_EPUB_FONT_SIZE_KEY,
                state.reader_defaults.epub_font_size.to_string(),
            );
            let changes = apply_reader_defaults_to_open_tabs(state);
            return reader_defaults_changed_task(state, changes);
        }

        Message::DefaultEpubFontSizeDown => {
            state.reader_defaults.epub_font_size =
                (state.reader_defaults.epub_font_size - 2.0).max(8.0);
            save_preference(
                state,
                DEFAULT_EPUB_FONT_SIZE_KEY,
                state.reader_defaults.epub_font_size.to_string(),
            );
            let changes = apply_reader_defaults_to_open_tabs(state);
            return reader_defaults_changed_task(state, changes);
        }

        Message::SelectDefaultEpubLineSpacing(line_spacing) => {
            state.reader_defaults.epub_line_spacing = line_spacing.clamp(1.0, 2.4);
            save_preference(
                state,
                DEFAULT_EPUB_LINE_SPACING_KEY,
                state.reader_defaults.epub_line_spacing.to_string(),
            );
            let changes = apply_reader_defaults_to_open_tabs(state);
            return reader_defaults_changed_task(state, changes);
        }

        Message::SelectDefaultPdfFitWidth(fit_width) => {
            state.reader_defaults.pdf_zoom = if fit_width {
                ZoomMode::FitWidth
            } else {
                ZoomMode::FitPage
            };
            save_preference(
                state,
                DEFAULT_PDF_ZOOM_KEY,
                if fit_width { "fit-width" } else { "fit-page" },
            );
            let changes = apply_reader_defaults_to_open_tabs(state);
            return reader_defaults_changed_task(state, changes);
        }

        Message::OpenManagedLibraryFolder => {
            let Some(library) = &state.library else {
                return Task::none();
            };
            let path = library.managed_dir().to_path_buf();
            if let Err(error) = std::fs::create_dir_all(&path)
                .and_then(|_| open::that(&path).map_err(std::io::Error::other))
            {
                state.settings_error = Some(error.to_string());
            }
        }

        Message::ChooseManagedLibraryParent => {
            if state.library.is_none()
                || state.moving_library
                || state.adding_books
                || state.removing_book.is_some()
            {
                return Task::none();
            }
            state.managed_library_move_generation =
                state.managed_library_move_generation.wrapping_add(1);
            let generation = state.managed_library_move_generation;
            let title = state.i18n.text("choose-managed-library-parent");
            return Task::perform(
                async move {
                    rfd::AsyncFileDialog::new()
                        .set_title(&title)
                        .pick_folder()
                        .await
                        .map(|folder| folder.path().to_path_buf())
                },
                move |parent| Message::ManagedLibraryParentSelected { generation, parent },
            );
        }

        Message::ManagedLibraryParentSelected { generation, parent } => {
            if generation != state.managed_library_move_generation {
                return Task::none();
            }
            let (Some(parent), Some(library)) = (parent, state.library.clone()) else {
                return Task::none();
            };
            let destination =
                parent.join(shosai_core::reading_state::managed_library_folder_name());
            if library.managed_dir() == destination {
                return Task::none();
            }
            state.settings_error = None;
            return Task::perform(
                async move {
                    library
                        .managed_storage_summary()
                        .await
                        .map_err(|error| format!("{error:#}"))
                },
                move |result| Message::ManagedLibraryMovePlanned {
                    generation,
                    destination: destination.clone(),
                    result,
                },
            );
        }

        Message::ManagedLibraryMovePlanned {
            generation,
            destination,
            result,
        } if generation == state.managed_library_move_generation => match result {
            Ok(summary) => {
                state.pending_library_move = Some(LibraryMovePlan {
                    destination,
                    summary,
                });
            }
            Err(error) => state.settings_error = Some(error),
        },

        Message::ManagedLibraryMovePlanned { .. } => {}

        Message::CancelManagedLibraryMove => {
            if !state.moving_library {
                state.pending_library_move = None;
                state.managed_library_move_generation =
                    state.managed_library_move_generation.wrapping_add(1);
            }
        }

        Message::ConfirmManagedLibraryMove => {
            if state.moving_library || state.adding_books || state.removing_book.is_some() {
                return Task::none();
            }
            let (Some(plan), Some(library)) =
                (state.pending_library_move.as_ref(), state.library.clone())
            else {
                return Task::none();
            };
            let destination = plan.destination.clone();
            let generation = state.managed_library_move_generation;
            let relocation_destination = destination.clone();
            let saves = state.reading_state_saves.clone();
            state.moving_library = true;
            state.settings_error = None;
            return Task::perform(
                async move {
                    if let Some(saves) = saves {
                        let (flushed, wait) = oneshot::channel();
                        saves
                            .send(ReadingStateWriterMessage::Flush(flushed))
                            .map_err(|error| error.to_string())?;
                        wait.await
                            .map_err(|_| "state writer stopped before relocation".to_owned())?
                            .map_err(|error| error.to_string())?;
                    }
                    shosai_core::reading_state::prepare_managed_library_directory(
                        &relocation_destination,
                    )
                    .map_err(|error| format!("{error:#}"))?;
                    library
                        .relocate_managed_books(&relocation_destination)
                        .await
                        .map_err(|error| format!("{error:#}"))
                },
                move |result| Message::ManagedLibraryMoved {
                    generation,
                    destination: destination.clone(),
                    result,
                },
            );
        }

        Message::ManagedLibraryMoved {
            generation,
            destination,
            result,
        } if generation == state.managed_library_move_generation => {
            state.moving_library = false;
            match result {
                Ok(changes) => {
                    apply_managed_path_changes(state, &changes);
                    let destination = destination.canonicalize().unwrap_or(destination);
                    if let Some(library) = &state.library {
                        state.library = Some(library.with_managed_dir(destination));
                    }
                    state.pending_library_move = None;
                    return Task::batch([
                        reset_library(state),
                        continue_close_after_durable_mutations(state),
                    ]);
                }
                Err(error) => state.settings_error = Some(error),
            }
            return continue_close_after_durable_mutations(state);
        }

        Message::ManagedLibraryMoved { .. } => {}

        // Bookmarks
        Message::ToggleBookmark => {
            if let (Some(tab_id), Some(path), Some(_store)) =
                (state.active_tab_id, &state.file_path, &state.bookmark_store)
            {
                let path = path.clone();
                let book_id = state.book_id;
                let page = state.current_page;
                let location_offset = current_epub_offset(state);
                state.bookmark_mutation_generation =
                    state.bookmark_mutation_generation.wrapping_add(1);
                let generation = state.bookmark_mutation_generation;
                return queue_bookmark_mutation(
                    state,
                    tab_id,
                    BookmarkMutation::Toggle {
                        generation,
                        file_path: path,
                        content_hash: state.document_content_hash.clone(),
                        book_id,
                        page,
                        location_offset,
                    },
                );
            }
        }

        Message::BookmarkToggled {
            tab_id,
            generation,
            file_path,
            book_id,
            page,
            location_offset,
            result,
        } => {
            let _ = (page, location_offset);
            if let Err(error) = result {
                eprintln!("warning: failed to toggle bookmark: {error}");
            }
            return finish_bookmark_mutation(state, tab_id, generation, &file_path, book_id);
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
            generation,
            file_path,
            book_id,
            bookmarks,
        } => {
            if state.active_tab_id != Some(tab_id)
                || state.bookmark_mutation_generation != generation
                || state.file_path.as_ref() != Some(&file_path)
                || state.book_id != book_id
            {
                return Task::none();
            }
            state.bookmarks = bookmarks;
            update_bookmark_status(state);
        }

        Message::GoToBookmark(page, location_offset) => {
            return navigate_to_saved_location(state, page, location_offset);
        }

        Message::StartEditNote(id, existing) => {
            state.editing_note_id = Some(id);
            state.editing_note_text = existing;
        }

        Message::EditNoteChanged(text) => {
            state.editing_note_text = text;
        }

        Message::SaveNote => {
            if let (Some(tab_id), Some(path), Some(id), Some(_store)) = (
                state.active_tab_id,
                &state.file_path,
                state.editing_note_id,
                &state.bookmark_store,
            ) {
                let note = if state.editing_note_text.is_empty() {
                    None
                } else {
                    Some(state.editing_note_text.clone())
                };
                let file_path = path.clone();
                let book_id = state.book_id;
                state.bookmark_mutation_generation =
                    state.bookmark_mutation_generation.wrapping_add(1);
                let generation = state.bookmark_mutation_generation;
                state.editing_note_id = None;
                state.editing_note_text = String::new();
                return queue_bookmark_mutation(
                    state,
                    tab_id,
                    BookmarkMutation::UpdateNote {
                        generation,
                        file_path,
                        book_id,
                        id,
                        note,
                    },
                );
            }
            state.editing_note_id = None;
            state.editing_note_text = String::new();
        }

        Message::CancelEditNote => {
            state.editing_note_id = None;
            state.editing_note_text = String::new();
        }

        Message::DeleteBookmark(id) => {
            if let (Some(tab_id), Some(path), Some(_store)) =
                (state.active_tab_id, &state.file_path, &state.bookmark_store)
            {
                let file_path = path.clone();
                let book_id = state.book_id;
                state.bookmark_mutation_generation =
                    state.bookmark_mutation_generation.wrapping_add(1);
                let generation = state.bookmark_mutation_generation;
                return queue_bookmark_mutation(
                    state,
                    tab_id,
                    BookmarkMutation::Delete {
                        generation,
                        file_path,
                        book_id,
                        id,
                    },
                );
            }
        }

        Message::BookmarkMutationFinished {
            tab_id,
            generation,
            file_path,
            book_id,
            result,
        } => {
            if let Err(error) = result {
                eprintln!("warning: failed to update bookmark: {error}");
                restore_failed_bookmark_edit(state, tab_id, generation);
            }
            return finish_bookmark_mutation(state, tab_id, generation, &file_path, book_id);
        }

        Message::ExportBookmarks => {
            if let (Some(path), Some(content_hash), Some(store)) = (
                &state.file_path,
                &state.document_content_hash,
                &state.bookmark_store,
            ) {
                match store.export_markdown(path, content_hash) {
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
                    cancel_active_search(state);
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
            cancel_active_search(state);
            state.search_query = query;
            state.search_query_generation = state.search_query_generation.wrapping_add(1);
            state.search_results.clear();
            state.search_current = 0;
            let render_task = refresh_pdf_search_highlights_if_changed(state, &previous_highlights);
            if !state.search_query.is_empty() {
                let Some(tab_id) = state.active_tab_id else {
                    return render_task;
                };
                let document_generation = state.search_document_generation;
                let query_generation = state.search_query_generation;
                let debounce = Task::perform(
                    async move {
                        tokio::time::sleep(SEARCH_DEBOUNCE).await;
                        (tab_id, document_generation, query_generation)
                    },
                    |(tab_id, document_generation, query_generation)| {
                        Message::SearchQueryDebounced {
                            tab_id,
                            document_generation,
                            query_generation,
                        }
                    },
                );
                return Task::batch([render_task, debounce]);
            }
            return render_task;
        }

        Message::SearchQueryDebounced {
            tab_id,
            document_generation,
            query_generation,
        } => {
            if state.active_tab_id == Some(tab_id)
                && state.search_document_generation == document_generation
                && state.search_query_generation == query_generation
                && !state.search_query.is_empty()
            {
                return perform_search(state);
            }
        }

        Message::SearchPerformed {
            tab_id,
            document_generation,
            query_generation,
            result,
        } => {
            if state.active_tab_id == Some(tab_id)
                && document_generation == state.search_document_generation
                && query_generation == state.search_query_generation
            {
                state.search_cancellation = None;
                state.search_loading = false;
                state.search_waiting = false;
                let previous_highlights = current_page_search_highlights(state);
                match result {
                    Ok(results) => {
                        state.search_results = results;
                        state.search_current = 0;
                        // Navigate to first result if any.
                        return navigate_to_current_search_result(state, &previous_highlights);
                    }
                    Err(SearchError::Cancelled) => {}
                    Err(error) => state.error = Some(AppError::Render(error.to_string())),
                }
            } else if state.search_waiting && !state.search_query.is_empty() {
                return perform_search(state);
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
            cancel_active_search(state);
            if uses_paginated_raster_layout(state) {
                return refresh_content(state);
            }
            return Task::batch([
                refresh_pdf_search_highlights_if_changed(state, &previous_highlights),
                scroll_to_current_page(state),
            ]);
        }

        Message::EpubPaginated {
            tab_id,
            generation,
            layout_key,
            complete,
            pages,
        } => {
            let job = EpubJob {
                tab_id,
                generation,
                layout_key,
            };
            let Some(cancelled) = state
                .epub_jobs
                .get(&job)
                .map(EpubPaginationCancellation::is_cancelled)
            else {
                return Task::none();
            };
            if complete {
                state.epub_jobs.remove(&job);
            }
            if cancelled {
                if complete
                    && state.epub_jobs.is_empty()
                    && matches!(state.document, Some(OpenDocument::Epub(_)))
                    && state.epub_layout_pending.is_none()
                    && state.epub_layout_requested.is_some()
                {
                    return refresh_content(state);
                }
                return Task::none();
            }
            let active = state.active_tab_id == Some(tab_id);
            let accepts_active_layout = active
                && generation == state.render_generation
                && layout_key == epub_layout_key(state);
            let active_request_completed =
                active && complete && state.epub_layout_pending == Some(layout_key);
            if active_request_completed {
                state.epub_layout_pending = None;
            }
            if accepts_active_layout {
                if !complete && state.epub_layout_key == Some(layout_key) {
                    return Task::none();
                }
                state.epub_pages = pages;
                state.epub_layout_key = Some(layout_key);
                if state.epub_pages.is_empty() {
                    state.epub_page = 0;
                    state.error = Some(AppError::EpubEmpty);
                } else {
                    let requested_page =
                        epub_page_for_location(state, state.current_page, state.epub_offset);
                    state.epub_page = requested_page.min(state.epub_pages.len() - 1);
                    state.page_input = (state.epub_page + 1).to_string();
                    state.error = None;
                    update_bookmark_status(state);
                }
            } else if let Some(index) = state.tabs.iter().position(|tab| tab.id == tab_id) {
                let accepts_layout = generation == state.tabs[index].render_generation
                    && layout_key == epub_layout_key_for_tab(state, &state.tabs[index]);
                if complete && state.tabs[index].epub_layout_pending == Some(layout_key) {
                    state.tabs[index].epub_layout_pending = None;
                }
                if accepts_layout {
                    let tab = &mut state.tabs[index];
                    if !complete && tab.epub_layout_key == Some(layout_key) {
                        return Task::none();
                    }
                    tab.epub_pages = pages;
                    tab.epub_layout_key = Some(layout_key);
                    if tab.epub_pages.is_empty() {
                        tab.epub_page = 0;
                        tab.error = Some(AppError::EpubEmpty);
                    } else {
                        tab.epub_page = epub_page_for_pages(
                            &tab.epub_pages,
                            tab.session.location.page,
                            tab.session.location.offset.unwrap_or_default(),
                        )
                        .min(tab.epub_pages.len() - 1);
                        tab.page_input = (tab.epub_page + 1).to_string();
                        tab.error = None;
                    }
                }
            }
            if active_request_completed
                && (!accepts_active_layout || state.epub_layout_requested != Some(layout_key))
            {
                return refresh_content(state);
            }
            if complete
                && state.epub_jobs.is_empty()
                && matches!(state.document, Some(OpenDocument::Epub(_)))
                && state.epub_layout_pending.is_none()
                && state.epub_layout_requested.is_some()
                && (state.epub_layout_key != state.epub_layout_requested
                    || state.epub_pages.is_empty())
            {
                return refresh_content(state);
            }
        }

        Message::EpubImageSizeLoaded {
            tab_id,
            generation,
            path,
            byte_len,
        } => {
            let job = EpubImageJob {
                tab_id,
                generation,
                path: path.clone(),
            };
            if !state.epub_image_jobs.contains(&job) {
                return Task::none();
            }
            if state.active_tab_id == Some(tab_id) && generation == state.epub_image_generation {
                if let Some(byte_len) = byte_len
                    && state.epub_images_desired.contains(&path)
                {
                    let transient_byte_len = match &state.document {
                        Some(OpenDocument::Epub(document)) => {
                            epub_image_transient_byte_len(document, &path)
                        }
                        _ => None,
                    };
                    if byte_len > state.epub_image_budget.limit()
                        || transient_byte_len
                            .is_none_or(|bytes| bytes > state.transient_decode_budget.limit())
                    {
                        state.epub_image_jobs.remove(&job);
                        state.epub_image_decode_active = false;
                        state.epub_images_pending.remove(&path);
                        state.epub_images_desired.remove(&path);
                        state.epub_images_failed.insert(path);
                        return load_epub_images_task(state);
                    }
                    if let Some(task) = decode_epub_image_task(state, job.clone(), byte_len) {
                        return task;
                    }
                    state.epub_image_jobs.remove(&job);
                    state.epub_image_decode_active = false;
                    state.epub_images_pending.remove(&path);
                    let current_paths = match &state.document {
                        Some(OpenDocument::Epub(document)) => {
                            let chapters = document.presentation().chapters();
                            epub_image_paths(
                                chapters[state.current_page.min(chapters.len() - 1)].nodes(),
                            )
                        }
                        _ => HashSet::new(),
                    };
                    // The first image in document order wins when the current
                    // chapter cannot retain all its images simultaneously.
                    // Transient contention remains retryable and is pumped by
                    // every raster/image worker completion.
                    if state.transient_decode_budget.used() == 0
                        && current_paths.contains(&path)
                        && state.epub_image_budget.used().saturating_add(byte_len)
                            > state.epub_image_budget.limit()
                    {
                        state.epub_images_desired.remove(&path);
                        state.epub_images_failed.insert(path);
                        return load_epub_images_task(state);
                    }
                    return Task::none();
                }
                state.epub_image_jobs.remove(&job);
                state.epub_image_decode_active = false;
                state.epub_images_pending.remove(&path);
                if byte_len.is_none() && state.epub_images_desired.remove(&path) {
                    state.epub_images_failed.insert(path);
                }
            } else if let Some(tab) = state.tabs.iter_mut().find(|tab| tab.id == tab_id)
                && generation == tab.epub_image_generation
            {
                state.epub_image_jobs.remove(&job);
                tab.epub_image_decode_active = false;
                tab.epub_images_pending.remove(&path);
            } else {
                state.epub_image_jobs.remove(&job);
            }
            return pump_background_work(state);
        }

        Message::EpubImagesDecoded {
            tab_id,
            generation,
            path,
            images,
        } => {
            if !state.epub_image_jobs.remove(&EpubImageJob {
                tab_id,
                generation,
                path,
            }) {
                return Task::none();
            }
            if state.active_tab_id == Some(tab_id) && generation == state.epub_image_generation {
                state.epub_image_decode_active = false;
                for (path, decoded) in images {
                    state.epub_images_pending.remove(&path);
                    if state.epub_images_desired.remove(&path) {
                        if let Some(decoded) = decoded {
                            state.epub_image_handles.insert(path, decoded.into_handle());
                        } else {
                            state.epub_images_failed.insert(path);
                        }
                    }
                }
            } else if let Some(tab) = state.tabs.iter_mut().find(|tab| tab.id == tab_id)
                && generation == tab.epub_image_generation
            {
                tab.epub_image_decode_active = false;
                for (path, decoded) in images {
                    tab.epub_images_pending.remove(&path);
                    if tab.epub_images_desired.remove(&path) {
                        if let Some(decoded) = decoded {
                            tab.epub_image_handles.insert(path, decoded.into_handle());
                        } else {
                            tab.epub_images_failed.insert(path);
                        }
                    }
                }
            }
            return pump_background_work(state);
        }

        Message::CbzDimensionsLoaded {
            tab_id,
            generation,
            page,
            result,
        } => {
            let job = CbzDimensionJob {
                tab_id,
                generation,
                page,
            };
            if state.cbz_dimension_jobs.remove(&job).is_none() {
                return Task::none();
            }
            if state.active_tab_id == Some(tab_id) && generation == state.render_generation {
                match result {
                    Ok(()) => return refresh_content(state),
                    Err(error) => {
                        state.cbz_dimension_failures.insert(job);
                        state.error = Some(AppError::Render(error));
                        return pump_background_work(state);
                    }
                }
            } else {
                return if matches!(state.document, Some(OpenDocument::Cbz(_))) {
                    pump_cbz_dimension_queue(state)
                } else {
                    pump_raster_queue(state)
                };
            }
        }

        Message::PageRendered {
            tab_id,
            generation,
            key,
            result,
        } => {
            let job = RasterJob::Paginated {
                tab_id,
                generation,
                key: key.clone(),
            };
            let Some(permit) = state.raster_jobs.remove(&job) else {
                return Task::none();
            };
            let active = state.active_tab_id == Some(tab_id);
            let was_pending = if active {
                state
                    .paginated_pending
                    .iter()
                    .position(|pending| pending == &key)
                    .map(|position| state.paginated_pending.remove(position))
                    .is_some()
            } else if let Some(tab) = state.tabs.iter_mut().find(|tab| tab.id == tab_id) {
                tab.paginated_pending
                    .iter()
                    .position(|pending| pending == &key)
                    .map(|position| tab.paginated_pending.remove(position))
                    .is_some()
            } else {
                false
            };
            let request_was_superseded = active
                && was_pending
                && state.paginated_pending.is_empty()
                && generation != state.render_generation;
            if !active || generation != state.render_generation {
                drop(permit);
                if request_was_superseded {
                    return Task::batch([refresh_content(state), load_epub_images_task(state)]);
                }
                return pump_background_work(state);
            }
            match result {
                Ok(page) => {
                    let Some(page) = attach_raster_permit(page, permit) else {
                        state.raster_failures.insert(job.failure());
                        state.error = Some(AppError::Render(
                            "rendered page exceeds its admitted raster budget".to_owned(),
                        ));
                        return pump_background_work(state);
                    };
                    let is_visible = paginated_raster_pages(state).contains(&key.page);
                    cache_rendered_page(state, key, page);
                    let spread_changed = is_visible && show_cached_paginated_spread(state);
                    if !has_current_raster_failure(state) {
                        state.error = None;
                    }
                    if spread_changed {
                        return Task::batch([
                            prefetch_next_paginated_spread(state),
                            load_epub_images_task(state),
                        ]);
                    }
                }
                Err(error) => {
                    drop(permit);
                    state.raster_failures.insert(job.failure());
                    if paginated_raster_pages(state).contains(&key.page) {
                        state.rendered_page = None;
                        state.rendered_page_index = None;
                        state.rendered_page_handle = None;
                        state.rendered_facing_page = None;
                        state.rendered_facing_page_handle = None;
                        state.error = Some(AppError::Render(error));
                    }
                }
            }
            return pump_background_work(state);
        }

        Message::ContinuousPageRendered {
            tab_id,
            request,
            page,
            result,
        } => {
            let job = RasterJob::Continuous {
                tab_id,
                request,
                page,
            };
            let Some(permit) = state.raster_jobs.remove(&job) else {
                return Task::none();
            };
            if state.active_tab_id != Some(tab_id) {
                if let Some(tab) = state.tabs.iter_mut().find(|tab| tab.id == tab_id)
                    && tab.continuous_pending.get(&page) == Some(&request)
                {
                    tab.continuous_pending.remove(&page);
                }
                drop(permit);
                return pump_background_work(state);
            }
            if state.active_tab_id == Some(tab_id) {
                if state.continuous_pending.get(&page) != Some(&request) {
                    drop(permit);
                    return pump_background_work(state);
                }
                state.continuous_pending.remove(&page);
                if page >= state.continuous_pages.len() {
                    drop(permit);
                    return pump_background_work(state);
                }
                match (request.generation == state.render_generation, result) {
                    (true, Ok(rendered))
                        if rendered.pixels.len() <= permit.weight()
                            && retained_continuous_raster_bytes(state)
                                .saturating_add(rendered.pixels.len())
                                <= CONTINUOUS_RASTER_BYTE_CAPACITY =>
                    {
                        state.continuous_pages[page] = attach_raster_permit(rendered, permit);
                        if page == state.current_page {
                            return Task::batch([
                                reconcile_continuous_rasters(state),
                                scroll_to_current_page(state),
                            ]);
                        }
                    }
                    (true, Err(error)) => {
                        drop(permit);
                        state.raster_failures.insert(job.failure());
                        if page == state.current_page {
                            state.error = Some(AppError::Render(error));
                            return pump_background_work(state);
                        }
                        state.continuous_visible.remove(&page);
                        return pump_background_work(state);
                    }
                    (true, Ok(_)) => {
                        drop(permit);
                        state.raster_failures.insert(job.failure());
                        if page == state.current_page {
                            state.error = Some(AppError::Render(
                                "rendered page exceeds the continuous raster budget".to_owned(),
                            ));
                        }
                        return pump_background_work(state);
                    }
                    (false, _) => {
                        drop(permit);
                        return pump_background_work(state);
                    }
                }
                return pump_background_work(state);
            }
        }

        Message::KeyPressed(event) => {
            return handle_key_event(state, event);
        }

        Message::WindowEvent(id, event) => {
            if state.close_after_geometry_save.is_some() {
                return Task::none();
            }
            state.window_id = Some(id);
            let mut application_icon = Task::none();
            match event {
                window::Event::Opened { position, size } => {
                    state.window_size = size;
                    state.window_position = position;
                    perf::window_resized(state, size);
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
                    perf::window_resized(state, size);
                    invalidate_continuous_layout(state);
                }
                window::Event::Rescaled(scale_factor) => {
                    state.window_scale_generation = state.window_scale_generation.wrapping_add(1);
                    return update_window_scale_factor(state, scale_factor);
                }
                window::Event::Moved(position) => state.window_position = Some(position),
                window::Event::CloseRequested => {
                    state.close_after_geometry_save = Some(id);
                    state.close_flush_started = false;
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
            return continue_close_after_durable_mutations(state);
        }

        Message::ReadingStateFlushed { id, result: Ok(()) } => return window::close(id),

        Message::ReadingStateFlushed {
            result: Err(error), ..
        } => {
            state.close_after_geometry_save = None;
            state.close_flush_started = false;
            state.open_error = Some(AppError::Storage(error));
        }

        Message::PerfFramePresented => return perf::frame_presented(state),
    }

    Task::none()
}
