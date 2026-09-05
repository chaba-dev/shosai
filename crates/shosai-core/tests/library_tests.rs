use sha2::{Digest, Sha256};
use shosai_core::bookmarks::BookmarkStore;
use shosai_core::library::{
    BookFormat, ImportCancellation, ImportDiscoveryProgress, ImportDuplicate, ImportFailure,
    Library, MANAGED_LIBRARY_DIR_PREFERENCE, StorageKind,
};
use shosai_core::path_from_key;
use shosai_core::reading_state::{FileReadingState, ReadingStateStore};
use shosai_core::state_writer::{StateSave, StateWriterMessage, start_state_writer};
use std::path::PathBuf;
use tempfile::TempDir;

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(name)
}

async fn temp_library() -> (Library, ReadingStateStore, TempDir) {
    let dir = TempDir::new().unwrap();
    let db_path = dir.path().join("shosai.db");
    let store = ReadingStateStore::open_at_async(&db_path).await.unwrap();
    let library = Library::new(store.pool().clone(), store.managed_books_dir());
    (library, store, dir)
}

#[tokio::test]
async fn malformed_library_rows_return_an_error_instead_of_being_omitted() {
    let (library, store, _dir) = temp_library().await;
    sqlx::query(
        "INSERT INTO books (title, format, file_path, storage_kind)
         VALUES ('Malformed', 'unknown', '/books/malformed', 'referenced')",
    )
    .execute(store.pool())
    .await
    .unwrap();

    assert!(library.list_all().await.is_err());
}

#[tokio::test]
async fn oversized_persisted_book_fields_are_rejected_before_dto_decode() {
    let (library, store, _dir) = temp_library().await;
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO books (title, format, file_path, storage_kind, cover_blob)
         VALUES ('Oversized', 'pdf', '/books/oversized.pdf', 'referenced', ?)
         RETURNING id",
    )
    .bind(vec![0_u8; 512 * 1024 + 1])
    .fetch_one(store.pool())
    .await
    .unwrap();

    assert!(library.get(id).await.is_err());
    assert!(library.page(None, None, 10, 0).await.is_err());
}

#[tokio::test]
async fn discovery_failures_do_not_retain_oversized_root_paths() {
    let (library, _, _dir) = temp_library().await;
    let oversized = PathBuf::from("x".repeat(20 * 1024));

    let discovery = library.discover_files(&[oversized]).await;

    assert_eq!(discovery.failures.len(), 1);
    assert!(discovery.failures[0].path().as_os_str().is_empty());
}

#[tokio::test]
async fn test_import_pdf() {
    let (lib, _, _dir) = temp_library().await;
    let book = lib.import_file(&fixture_path("sample.pdf")).await.unwrap();
    assert_eq!(book.format, BookFormat::Pdf);
    assert!(!book.title.is_empty());
}

#[tokio::test]
async fn test_import_epub() {
    let (lib, _, _dir) = temp_library().await;
    let book = lib.import_file(&fixture_path("sample.epub")).await.unwrap();
    assert_eq!(book.format, BookFormat::Epub);
    assert_eq!(book.title, "Sample Book");
    assert_eq!(book.author.as_deref(), Some("Test Author"));
}

#[tokio::test]
async fn test_import_cbz() {
    let (lib, _, _dir) = temp_library().await;
    let book = lib.import_file(&fixture_path("sample.cbz")).await.unwrap();
    assert_eq!(book.format, BookFormat::Cbz);
    assert_eq!(book.title, "sample");
}

#[tokio::test]
async fn test_import_duplicate_returns_existing() {
    let (lib, _, _dir) = temp_library().await;
    let book1 = lib.import_file(&fixture_path("sample.pdf")).await.unwrap();
    let book2 = lib.import_file(&fixture_path("sample.pdf")).await.unwrap();
    assert_eq!(book1.id, book2.id);
}

#[tokio::test]
async fn direct_import_rejects_replaced_existing_path() {
    let (lib, _, dir) = temp_library().await;
    let path = dir.path().join("book.epub");
    std::fs::copy(fixture_path("sample.epub"), &path).unwrap();
    lib.import_file(&path).await.unwrap();
    let mut replacement = std::fs::read(&path).unwrap();
    let comment_length = replacement.len() - 2;
    replacement[comment_length..].copy_from_slice(&1_u16.to_le_bytes());
    replacement.push(b'x');
    std::fs::write(&path, replacement).unwrap();

    let error = lib.import_file(&path).await.unwrap_err();
    assert!(
        error.to_string().contains("no longer match"),
        "unexpected error: {error:#}"
    );
}

#[tokio::test]
async fn stable_book_open_rejects_replaced_content() {
    let (lib, _, dir) = temp_library().await;
    let path = dir.path().join("book.epub");
    std::fs::copy(fixture_path("sample.epub"), &path).unwrap();
    let book = lib.import_file(&path).await.unwrap();
    std::fs::copy(fixture_path("epub-conformance/links.epub"), &path).unwrap();

    let error = lib.open_book_document_at(book.id, &path).await.unwrap_err();
    assert!(
        error.to_string().contains("no longer match"),
        "unexpected error: {error:#}"
    );
}

#[tokio::test]
async fn reviewed_import_rejects_replaced_existing_path() {
    use std::io::Write;

    let (lib, _, dir) = temp_library().await;
    let path = dir.path().join("book.epub");
    std::fs::copy(fixture_path("sample.epub"), &path).unwrap();
    lib.import_file(&path).await.unwrap();
    let candidate = lib.discover_files(std::slice::from_ref(&path)).await;
    assert_eq!(candidate.candidates.len(), 1);
    std::fs::OpenOptions::new()
        .append(true)
        .open(&path)
        .unwrap()
        .write_all(b"replacement")
        .unwrap();

    let report = lib.link_discovered_files(&candidate.candidates).await;
    assert_eq!(report.succeeded, 0);
    assert_eq!(report.failures().len(), 1);
    assert!(
        report.failures()[0]
            .error()
            .contains("changed after review")
    );
}

#[cfg(all(unix, not(target_os = "macos")))]
#[tokio::test]
async fn non_unicode_library_paths_remain_distinct_and_reopenable() {
    use std::ffi::OsString;
    use std::os::unix::ffi::OsStringExt;

    use shosai_core::application::{DeviceFileLocator, OpenDocument};

    let (lib, _, dir) = temp_library().await;
    let first = dir
        .path()
        .join(OsString::from_vec(b"book-\x80.epub".to_vec()));
    let second = dir
        .path()
        .join(OsString::from_vec(b"book-\x81.epub".to_vec()));
    std::fs::copy(fixture_path("sample.epub"), &first).unwrap();
    std::fs::copy(fixture_path("sample.epub"), &second).unwrap();

    let first_book = lib.import_file(&first).await.unwrap();
    let second_book = lib.import_file(&second).await.unwrap();

    assert_ne!(first_book.id, second_book.id);
    assert_ne!(first_book.file_path, second_book.file_path);
    assert_eq!(
        path_from_key(&first_book.file_path),
        first.canonicalize().unwrap()
    );
    assert_eq!(
        path_from_key(&second_book.file_path),
        second.canonicalize().unwrap()
    );
    for book in lib.list_all().await.unwrap() {
        OpenDocument::open(&DeviceFileLocator::from_path(path_from_key(
            &book.file_path,
        )))
        .unwrap();
    }
}

#[tokio::test]
async fn test_list_all() {
    let (lib, _, _dir) = temp_library().await;
    lib.import_file(&fixture_path("sample.pdf")).await.unwrap();
    lib.import_file(&fixture_path("sample.epub")).await.unwrap();
    lib.import_file(&fixture_path("sample.cbz")).await.unwrap();

    let books = lib.list_all().await.unwrap();
    assert_eq!(books.len(), 3);
}

#[tokio::test]
async fn test_search_by_title() {
    let (lib, _, _dir) = temp_library().await;
    lib.import_file(&fixture_path("sample.epub")).await.unwrap();
    lib.import_file(&fixture_path("sample.pdf")).await.unwrap();

    let results = lib.search("Sample Book").await.unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].title, "Sample Book");
}

#[tokio::test]
async fn test_search_by_author() {
    let (lib, _, _dir) = temp_library().await;
    lib.import_file(&fixture_path("sample.epub")).await.unwrap();

    let results = lib.search("Test Author").await.unwrap();
    assert_eq!(results.len(), 1);
}

#[tokio::test]
async fn test_filter_by_format() {
    let (lib, _, _dir) = temp_library().await;
    lib.import_file(&fixture_path("sample.pdf")).await.unwrap();
    lib.import_file(&fixture_path("sample.epub")).await.unwrap();
    lib.import_file(&fixture_path("sample.cbz")).await.unwrap();

    let pdfs = lib.filter_by_format(BookFormat::Pdf).await.unwrap();
    assert_eq!(pdfs.len(), 1);
    assert_eq!(pdfs[0].format, BookFormat::Pdf);

    let epubs = lib.filter_by_format(BookFormat::Epub).await.unwrap();
    assert_eq!(epubs.len(), 1);
}

#[tokio::test]
async fn test_library_pages_are_bounded_and_combine_filters() {
    let (lib, _, _dir) = temp_library().await;
    lib.import_file(&fixture_path("sample.pdf")).await.unwrap();
    lib.import_file(&fixture_path("sample.epub")).await.unwrap();
    lib.import_file(&fixture_path("sample.cbz")).await.unwrap();

    let first = lib.page(None, None, 2, 0).await.unwrap();
    assert_eq!(first.books.len(), 2);
    assert!(first.has_more);

    let second = lib.page(None, None, 2, 2).await.unwrap();
    assert_eq!(second.books.len(), 1);
    assert!(!second.has_more);

    let filtered = lib
        .page(Some("Sample Book"), Some(BookFormat::Epub), 20, 0)
        .await
        .unwrap();
    assert_eq!(filtered.books.len(), 1);
    assert_eq!(filtered.books[0].format, BookFormat::Epub);
}

#[tokio::test]
async fn library_caps_pages_and_chunks_large_id_snapshots() {
    let (lib, store, _dir) = temp_library().await;
    for id in 0..1_005 {
        sqlx::query("INSERT INTO books (title, format, file_path) VALUES (?, 'pdf', ?)")
            .bind(format!("Book {id}"))
            .bind(format!("/synthetic/{id}.pdf"))
            .execute(store.pool())
            .await
            .unwrap();
    }

    let page = lib.page(None, None, u32::MAX, 0).await.unwrap();
    assert_eq!(page.books.len(), 500);
    assert!(page.has_more);
    assert!(
        lib.list_all()
            .await
            .unwrap_err()
            .to_string()
            .contains("use page()")
    );
    let ids = lib.matching_ids(None, None).await.unwrap();
    let books = lib.books_by_ids(&ids[..500]).await.unwrap();
    assert_eq!(books.len(), 500);
    assert_eq!(books.first().unwrap().id, ids[0]);
    assert_eq!(books.last().unwrap().id, ids[499]);
    assert!(
        lib.books_by_ids(&vec![0; 501])
            .await
            .unwrap_err()
            .to_string()
            .contains("page exceeds")
    );
    assert!(
        lib.page(Some(&"q".repeat(4 * 1024 + 1)), None, 10, 0)
            .await
            .unwrap_err()
            .to_string()
            .contains("query exceeds")
    );
}

#[tokio::test]
async fn discovery_caps_selected_roots_before_starting_scanners() {
    let (lib, _, _dir) = temp_library().await;
    let roots = vec![fixture_path("sample.epub"); 10_001];
    let progress = ImportDiscoveryProgress::default();

    let discovery = lib
        .discover_files_with_progress(roots, ImportCancellation::default(), progress.clone())
        .await;

    assert!(discovery.candidates.is_empty());
    assert!(!progress.snapshot().enumerating);
    assert_eq!(discovery.failures.len(), 1);
    assert!(
        discovery.failures[0]
            .error()
            .contains("too many import roots")
    );
}

#[tokio::test]
async fn library_order_queries_have_covering_sort_indexes() {
    let (_lib, store, _dir) = temp_library().await;
    let indexes: Vec<String> = sqlx::query_scalar("SELECT name FROM pragma_index_list('books')")
        .fetch_all(store.pool())
        .await
        .unwrap();

    assert!(
        indexes.iter().any(|name| name == "books_library_order_idx"),
        "missing unfiltered library order index: {indexes:?}"
    );
    assert!(
        indexes
            .iter()
            .any(|name| name == "books_format_library_order_idx")
    );
}

#[tokio::test]
async fn test_library_id_snapshot_stays_stable_when_sort_order_changes() {
    let (lib, _, _dir) = temp_library().await;
    let pdf = lib.import_file(&fixture_path("sample.pdf")).await.unwrap();
    let epub = lib.import_file(&fixture_path("sample.epub")).await.unwrap();
    let cbz = lib.import_file(&fixture_path("sample.cbz")).await.unwrap();

    let ids = lib.matching_ids(None, None).await.unwrap();
    lib.update_progress(pdf.id, 0.5).await.unwrap();

    let first = lib.books_by_ids(&ids[..2]).await.unwrap();
    let second = lib.books_by_ids(&ids[2..]).await.unwrap();
    let loaded_ids: Vec<_> = first
        .into_iter()
        .chain(second)
        .map(|book| book.id)
        .collect();

    assert_eq!(loaded_ids, ids);
    assert_eq!(loaded_ids.len(), 3);
    assert!(loaded_ids.contains(&epub.id));
    assert!(loaded_ids.contains(&cbz.id));
}

#[tokio::test]
async fn test_update_progress() {
    let (lib, _, _dir) = temp_library().await;
    let book = lib.import_file(&fixture_path("sample.pdf")).await.unwrap();
    assert!((book.progress - 0.0).abs() < f64::EPSILON);

    lib.update_progress(book.id, 0.5).await.unwrap();

    let books = lib.list_all().await.unwrap();
    let updated = books.iter().find(|b| b.id == book.id).unwrap();
    assert!((updated.progress - 0.5).abs() < f64::EPSILON);
    assert!(updated.last_read.is_some());
}

#[tokio::test]
async fn test_update_progress_by_path() {
    let (lib, _, _dir) = temp_library().await;
    let book = lib.import_file(&fixture_path("sample.pdf")).await.unwrap();

    lib.update_progress_by_path(&PathBuf::from(&book.file_path), 0.75)
        .await
        .unwrap();

    let books = lib.list_all().await.unwrap();
    let updated = books.iter().find(|b| b.id == book.id).unwrap();
    assert!((updated.progress - 0.75).abs() < f64::EPSILON);
    assert!(updated.last_read.is_some());
}

#[tokio::test]
async fn test_remove() {
    let (lib, _, _dir) = temp_library().await;
    let book = lib.import_file(&fixture_path("sample.pdf")).await.unwrap();

    lib.remove(book.id).await.unwrap();

    let books = lib.list_all().await.unwrap();
    assert!(books.is_empty());
}

#[tokio::test]
async fn test_cover_extracted_for_epub() {
    let (lib, _, _dir) = temp_library().await;
    let book = lib.import_file(&fixture_path("sample.epub")).await.unwrap();
    // Our sample EPUB has a cover image
    assert!(book.cover.is_some(), "EPUB should have a cover");
    let cover = book.cover.unwrap();
    // Should be valid PNG
    assert!(cover.starts_with(&[0x89, b'P', b'N', b'G']));
}

#[tokio::test]
async fn test_cover_extracted_for_cbz() {
    let (lib, _, _dir) = temp_library().await;
    let book = lib.import_file(&fixture_path("sample.cbz")).await.unwrap();
    assert!(book.cover.is_some(), "CBZ should have a cover");
    let cover = book.cover.unwrap();
    assert!(cover.starts_with(&[0x89, b'P', b'N', b'G']));
}

#[tokio::test]
async fn test_import_unsupported_format() {
    let (lib, _, dir) = temp_library().await;
    let txt_path = dir.path().join("test.txt");
    std::fs::write(&txt_path, "hello").unwrap();
    let result = lib.import_file(&txt_path).await;
    assert!(result.is_err());
}

#[tokio::test]
async fn test_import_directory() {
    let (lib, _, dir) = temp_library().await;

    // Create a directory with some fixtures copied in.
    let import_dir = dir.path().join("imports");
    std::fs::create_dir_all(&import_dir).unwrap();
    std::fs::copy(fixture_path("sample.pdf"), import_dir.join("book.pdf")).unwrap();
    std::fs::copy(fixture_path("sample.epub"), import_dir.join("book.epub")).unwrap();
    // Also a non-book file that should be skipped.
    std::fs::write(import_dir.join("notes.txt"), "some notes").unwrap();

    let report = lib.import_directory(&import_dir).await;
    assert_eq!(report.succeeded, 2);
    assert!(report.failures().is_empty());
}

#[cfg(unix)]
#[tokio::test]
async fn direct_directory_import_does_not_follow_directory_cycles() {
    use std::os::unix::fs::symlink;

    let (lib, _, dir) = temp_library().await;
    let root = dir.path().join("cycle");
    std::fs::create_dir(&root).unwrap();
    std::fs::copy(fixture_path("sample.epub"), root.join("book.epub")).unwrap();
    symlink(&root, root.join("again")).unwrap();

    let report = lib.link_directory(&root).await;

    assert_eq!(report.succeeded, 1);
    assert!(report.failures().is_empty());
}

#[tokio::test]
async fn discovery_groups_exact_filename_stems_without_importing() {
    let (lib, _, dir) = temp_library().await;
    let import_dir = dir.path().join("imports");
    std::fs::create_dir_all(&import_dir).unwrap();
    std::fs::copy(
        fixture_path("sample.pdf"),
        import_dir.join("Learning Rust.pdf"),
    )
    .unwrap();
    std::fs::copy(
        fixture_path("sample.epub"),
        import_dir.join("Learning   Rust.epub"),
    )
    .unwrap();
    std::fs::write(import_dir.join("notes.txt"), "not a book").unwrap();

    let discovery = lib.discover_directory(&import_dir).await;

    assert_eq!(discovery.candidates.len(), 2);
    assert!(discovery.failures.is_empty());
    assert_eq!(discovery.candidates[0].group_key, "learning rust");
    assert_eq!(discovery.candidates[1].group_key, "learning rust");
    assert_ne!(
        discovery.candidates[0].format,
        discovery.candidates[1].format
    );
    assert!(lib.list_all().await.unwrap().is_empty());
}

#[tokio::test]
async fn discovery_marks_books_already_in_the_library() {
    let (lib, _, _dir) = temp_library().await;
    let book = lib.import_file(&fixture_path("sample.pdf")).await.unwrap();

    let discovery = lib.discover_files(&[fixture_path("sample.pdf")]).await;

    assert_eq!(discovery.candidates.len(), 1);
    assert_eq!(
        discovery.candidates[0].duplicate,
        Some(ImportDuplicate::ExistingBook {
            book_id: book.id,
            title: book.title,
        })
    );
}

#[cfg(all(unix, not(target_os = "macos")))]
#[tokio::test]
async fn discovery_matches_changed_content_by_non_unicode_path() {
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;

    let (lib, _, dir) = temp_library().await;
    let path = dir.path().join(OsStr::from_bytes(b"changed-\x80.pdf"));
    std::fs::copy(fixture_path("sample.pdf"), &path).unwrap();
    let book = lib.import_file(&path).await.unwrap();
    let mut changed = std::fs::read(&path).unwrap();
    changed.push(b'\n');
    std::fs::write(&path, changed).unwrap();

    let discovery = lib.discover_files(&[path]).await;

    assert_eq!(discovery.candidates.len(), 1);
    assert_eq!(
        discovery.candidates[0].duplicate,
        Some(ImportDuplicate::ExistingBook {
            book_id: book.id,
            title: book.title,
        })
    );
}

#[tokio::test]
async fn same_content_duplicates_choose_the_lowest_referenced_book_id() {
    let (lib, _, dir) = temp_library().await;
    let first = dir.path().join("first.pdf");
    let second = dir.path().join("second.pdf");
    let third = dir.path().join("third.pdf");
    for path in [&first, &second, &third] {
        std::fs::copy(fixture_path("sample.pdf"), path).unwrap();
    }
    let first_book = lib.import_file(&first).await.unwrap();
    let second_book = lib.import_file(&second).await.unwrap();
    assert!(first_book.id < second_book.id);

    let discovery = lib.discover_files(std::slice::from_ref(&third)).await;

    assert_eq!(
        discovery.candidates[0].duplicate,
        Some(ImportDuplicate::ExistingBook {
            book_id: first_book.id,
            title: first_book.title,
        })
    );
}

#[tokio::test]
async fn discovery_marks_repeated_content_in_the_selection() {
    let (lib, _, dir) = temp_library().await;
    let first = dir.path().join("a.pdf");
    let second = dir.path().join("b.pdf");
    std::fs::copy(fixture_path("sample.pdf"), &first).unwrap();
    std::fs::copy(fixture_path("sample.pdf"), &second).unwrap();

    let discovery = lib.discover_files(&[second.clone(), first.clone()]).await;

    assert_eq!(discovery.candidates.len(), 2);
    assert!(discovery.candidates[0].duplicate.is_none());
    assert_eq!(
        discovery.candidates[1].duplicate,
        Some(ImportDuplicate::SelectedFile {
            path: first.canonicalize().unwrap(),
        })
    );
}

#[tokio::test]
async fn discovery_failure_order_is_stable() {
    let (lib, _, dir) = temp_library().await;
    let first = dir.path().join("a.pdf");
    let second = dir.path().join("z.epub");

    let forward = lib.discover_files(&[first.clone(), second.clone()]).await;
    let reverse = lib.discover_files(&[second.clone(), first.clone()]).await;

    let forward_paths: Vec<_> = forward.failures.iter().map(ImportFailure::path).collect();
    let reverse_paths: Vec<_> = reverse.failures.iter().map(ImportFailure::path).collect();
    assert_eq!(forward_paths, vec![&first, &second]);
    assert_eq!(reverse_paths, forward_paths);
}

#[tokio::test]
async fn discovery_groups_unicode_equivalent_stems() {
    let (lib, _, dir) = temp_library().await;
    let paths = [
        ("Straße.pdf", "sample.pdf"),
        ("STRASSE.epub", "sample.epub"),
        ("か\u{3099}.pdf", "sample.pdf"),
        ("が.epub", "sample.epub"),
    ]
    .map(|(name, fixture)| {
        let path = dir.path().join(name);
        std::fs::copy(fixture_path(fixture), &path).unwrap();
        path
    });

    let discovery = lib.discover_files(&paths).await;

    let mut keys: Vec<_> = discovery
        .candidates
        .iter()
        .map(|candidate| candidate.group_key.as_str())
        .collect();
    keys.sort_unstable();
    assert_eq!(keys, ["strasse", "strasse", "が", "が"]);
}

#[cfg(unix)]
#[tokio::test]
async fn discovery_skips_non_regular_files() {
    use std::os::unix::net::UnixListener;

    let (lib, _, dir) = temp_library().await;
    let socket_path = dir.path().join("not-a-book.pdf");
    let _listener = UnixListener::bind(&socket_path).unwrap();

    let discovery = lib.discover_directory(dir.path()).await;

    assert!(discovery.candidates.is_empty());
    assert!(discovery.failures.is_empty());
}

#[cfg(unix)]
#[tokio::test]
async fn discovery_uses_a_symlink_targets_format_and_path() {
    use std::os::unix::fs::symlink;

    let (lib, _, dir) = temp_library().await;
    let target = dir.path().join("actual.epub");
    let alias = dir.path().join("misleading.pdf");
    std::fs::copy(fixture_path("sample.epub"), &target).unwrap();
    symlink(&target, &alias).unwrap();

    let discovery = lib.discover_files(&[alias]).await;

    assert_eq!(discovery.candidates.len(), 1);
    assert_eq!(discovery.candidates[0].format, BookFormat::Epub);
    assert_eq!(discovery.candidates[0].path, target.canonicalize().unwrap());
    assert_eq!(discovery.candidates[0].title, "actual");
}

#[tokio::test]
async fn discovered_import_rejects_a_file_changed_after_review() {
    use std::io::Write;

    let (lib, _, dir) = temp_library().await;
    let source = dir.path().join("changing.epub");
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();
    let discovery = lib.discover_files(std::slice::from_ref(&source)).await;
    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .open(&source)
        .unwrap();
    file.write_all(b"changed after review").unwrap();

    let linked = lib.link_discovered_files(&discovery.candidates).await;
    let copied = lib.import_discovered_files(&discovery.candidates).await;

    assert_eq!(linked.succeeded, 0);
    assert_eq!(linked.failures().len(), 1);
    assert!(
        linked.failures()[0]
            .error()
            .contains("changed after review")
    );
    assert_eq!(copied.succeeded, 0);
    assert_eq!(copied.failures().len(), 1);
    assert!(
        copied.failures()[0]
            .error()
            .contains("changed after review")
    );
    assert!(lib.list_all().await.unwrap().is_empty());
}

#[tokio::test]
async fn confirmed_referenced_import_honors_cancellation() {
    let (lib, _, dir) = temp_library().await;
    let source = dir.path().join("cancelled.epub");
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();
    let mut discovery = lib.discover_files(std::slice::from_ref(&source)).await;
    let candidate = discovery.candidates.pop().unwrap();
    let cancellation = shosai_core::library::ImportCancellation::default();
    cancellation.cancel();

    let completion = lib
        .link_discovered_file_cancellable(candidate, cancellation)
        .await;

    assert!(matches!(
        completion,
        shosai_core::library::ImportCompletion::Cancelled
    ));
    assert!(lib.list_all().await.unwrap().is_empty());
}

#[tokio::test]
async fn discovered_referenced_duplicate_rejects_a_file_changed_after_review() {
    use std::io::Write;

    let (lib, _, dir) = temp_library().await;
    let source = dir.path().join("changing.epub");
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();
    lib.import_file(&source).await.unwrap();
    let discovery = lib.discover_files(std::slice::from_ref(&source)).await;
    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .open(&source)
        .unwrap();
    file.write_all(b"changed after review").unwrap();

    let linked = lib.link_discovered_files(&discovery.candidates).await;

    assert_eq!(linked.succeeded, 0);
    assert_eq!(linked.failures().len(), 1);
    assert!(
        linked.failures()[0]
            .error()
            .contains("changed after review")
    );
}

#[tokio::test]
async fn managed_import_preparation_is_concurrent_safe_and_does_not_mutate_the_library() {
    let (lib, _, dir) = temp_library().await;
    let first = dir.path().join("first.epub");
    let second = dir.path().join("second.epub");
    std::fs::copy(fixture_path("sample.epub"), &first).unwrap();
    std::fs::copy(fixture_path("sample.epub"), &second).unwrap();
    let mut candidates = lib.discover_files(&[first, second]).await.candidates;
    let second_candidate = candidates.pop().unwrap();
    let first_candidate = candidates.pop().unwrap();

    let (first_prepared, second_prepared) = tokio::join!(
        lib.prepare_discovered_managed_file(first_candidate),
        lib.prepare_discovered_managed_file(second_candidate),
    );
    let first_prepared = first_prepared.unwrap();
    let second_prepared = second_prepared.unwrap();

    assert!(lib.list_all().await.unwrap().is_empty());
    let first_book = lib
        .commit_prepared_managed_file(&first_prepared)
        .await
        .unwrap();
    let second_book = lib
        .commit_prepared_managed_file(&second_prepared)
        .await
        .unwrap();

    assert_eq!(first_book.id, second_book.id);
    assert_eq!(lib.list_all().await.unwrap().len(), 1);
}

#[tokio::test]
async fn cancelled_discovery_stops_before_scanning_candidates() {
    let (lib, _, _dir) = temp_library().await;
    let cancellation = ImportCancellation::default();
    cancellation.cancel();
    let progress = ImportDiscoveryProgress::default();

    let discovery = lib
        .discover_files_with_progress(
            vec![fixture_path("sample.epub")],
            cancellation,
            progress.clone(),
        )
        .await;

    assert!(discovery.candidates.is_empty());
    assert!(discovery.failures.is_empty());
    assert!(!progress.snapshot().enumerating);
}

#[tokio::test]
async fn discovery_progress_counts_supported_files_through_completion() {
    let (lib, _, dir) = temp_library().await;
    let first = dir.path().join("book.epub");
    let second = dir.path().join("book.pdf");
    std::fs::copy(fixture_path("sample.epub"), &first).unwrap();
    std::fs::copy(fixture_path("sample.pdf"), &second).unwrap();
    for index in 3..=6 {
        std::fs::copy(
            fixture_path("sample.epub"),
            dir.path().join(format!("book-{index}.epub")),
        )
        .unwrap();
    }
    std::fs::write(dir.path().join("notes.txt"), b"ignored").unwrap();
    let progress = ImportDiscoveryProgress::default();

    let discovery = lib
        .discover_directory_with_progress(
            dir.path().to_path_buf(),
            ImportCancellation::default(),
            progress.clone(),
        )
        .await;

    assert_eq!(discovery.candidates.len(), 6);
    let snapshot = progress.snapshot();
    assert!(!snapshot.enumerating);
    assert_eq!(snapshot.total_files, 6);
    assert_eq!(snapshot.hashed_files, 6);
    assert_eq!(snapshot.completed_files, 6);
}

#[tokio::test]
async fn directory_import_reports_when_every_supported_file_fails() {
    let (lib, _, dir) = temp_library().await;
    let import_dir = dir.path().join("imports");
    std::fs::create_dir_all(&import_dir).unwrap();
    std::fs::write(import_dir.join("corrupt.epub"), b"not an epub").unwrap();

    let report = lib.import_directory(&import_dir).await;

    assert_eq!(report.succeeded, 0);
    assert_eq!(report.failures().len(), 1);
    assert_eq!(
        report.failures()[0].path(),
        import_dir.join("corrupt.epub").canonicalize().unwrap()
    );
    assert!(lib.list_all().await.unwrap().is_empty());
}

#[tokio::test]
async fn directory_import_keeps_successes_and_reports_other_failures() {
    let (lib, _, dir) = temp_library().await;
    let import_dir = dir.path().join("imports");
    std::fs::create_dir_all(&import_dir).unwrap();
    std::fs::copy(fixture_path("sample.epub"), import_dir.join("valid.epub")).unwrap();
    std::fs::write(import_dir.join("corrupt.epub"), b"not an epub").unwrap();

    let report = lib.import_directory(&import_dir).await;

    assert_eq!(report.succeeded, 1);
    assert_eq!(report.failures().len(), 1);
    assert_eq!(lib.list_all().await.unwrap().len(), 1);
}

#[tokio::test]
async fn file_batch_continues_after_a_failure_and_reports_it() {
    let (lib, _, dir) = temp_library().await;
    let first = dir.path().join("first.pdf");
    let corrupt = dir.path().join("corrupt.epub");
    let last = dir.path().join("last.cbz");
    std::fs::copy(fixture_path("sample.pdf"), &first).unwrap();
    std::fs::write(&corrupt, b"not an epub").unwrap();
    std::fs::copy(fixture_path("sample.cbz"), &last).unwrap();

    let report = lib.import_files(&[first, corrupt.clone(), last]).await;

    assert_eq!(report.succeeded, 2);
    assert_eq!(report.failures().len(), 1);
    assert_eq!(report.failures()[0].path(), corrupt);
    assert_eq!(lib.list_all().await.unwrap().len(), 2);
}

#[tokio::test]
async fn linked_directory_keeps_books_in_their_original_locations() {
    let (lib, _, dir) = temp_library().await;
    let import_dir = dir.path().join("imports");
    std::fs::create_dir_all(&import_dir).unwrap();
    let source = import_dir.join("book.epub");
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();

    let report = lib.link_directory(&import_dir).await;

    assert_eq!(report.succeeded, 1);
    assert!(report.failures().is_empty());
    assert_eq!(
        report.imported()[0].library_path(),
        source.canonicalize().unwrap()
    );
}

#[tokio::test]
async fn managed_import_survives_the_source_being_removed() {
    let (lib, _, dir) = temp_library().await;
    let source = dir.path().join("source.epub");
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();

    let book = lib.import_managed_file(&source).await.unwrap();
    std::fs::remove_file(source).unwrap();

    assert_eq!(book.storage_kind, StorageKind::Managed);
    assert!(PathBuf::from(&book.file_path).exists());
    assert!(
        PathBuf::from(&book.file_path)
            .starts_with(dir.path().join("books").canonicalize().unwrap())
    );
    assert!(book.content_hash.is_some());
}

#[tokio::test]
async fn managed_promotion_reconciles_the_imported_source_alias() {
    let (lib, store, dir) = temp_library().await;
    let first = dir.path().join("first.epub");
    let imported_source = dir.path().join("second.epub");
    std::fs::copy(fixture_path("sample.epub"), &first).unwrap();
    std::fs::copy(fixture_path("sample.epub"), &imported_source).unwrap();
    let referenced = lib.import_file(&first).await.unwrap();
    let content_hash = referenced.content_hash.as_deref().unwrap();
    store
        .set_for_book_async(
            referenced.id,
            &FileReadingState {
                page: 1,
                location_offset: None,
                zoom: 1.0,
            },
        )
        .await
        .unwrap();
    store
        .set_async(
            &imported_source,
            content_hash,
            &FileReadingState {
                page: 9,
                location_offset: Some(3),
                zoom: 1.25,
            },
        )
        .await
        .unwrap();
    let bookmarks = BookmarkStore::new(store.pool().clone());
    bookmarks
        .toggle_at_async(&imported_source, content_hash, 4, Some(7), None)
        .await
        .unwrap();

    let managed = lib.import_managed_file(&imported_source).await.unwrap();

    assert_eq!(managed.id, referenced.id);
    assert_eq!(managed.storage_kind, StorageKind::Managed);
    let reading = store
        .get_for_book_async(referenced.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(reading.page, 9);
    assert_eq!(reading.location_offset, Some(3));
    let merged = bookmarks.list_for_book_async(referenced.id).await.unwrap();
    assert!(
        merged
            .iter()
            .any(|bookmark| bookmark.page == 4 && bookmark.location_offset == Some(7))
    );
}

#[tokio::test]
async fn managed_source_bookmark_add_lists_and_removes_through_its_alias() {
    let (lib, store, dir) = temp_library().await;
    let source = dir.path().join("source.epub");
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();
    let book = lib.import_managed_file(&source).await.unwrap();
    let hash = book.content_hash.as_deref().unwrap();
    let bookmarks = BookmarkStore::new(store.pool().clone());

    let added = bookmarks
        .add_async(&source, hash, 4, Some("Source"), None, "yellow")
        .await
        .unwrap();

    assert_eq!(added.book_id, Some(book.id));
    assert_eq!(added.file_path, book.file_path);
    assert_eq!(
        bookmarks
            .list_for_file_async(&source, hash)
            .await
            .unwrap()
            .len(),
        1
    );
    bookmarks
        .remove_all_for_file_async(&source, hash)
        .await
        .unwrap();
    assert!(
        bookmarks
            .list_for_book_async(book.id)
            .await
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn managed_import_does_not_repurpose_a_path_owner_with_different_content() {
    let (lib, _, dir) = temp_library().await;
    let source = dir.path().join("book.epub");
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();
    let original = lib.import_file(&source).await.unwrap();
    std::fs::copy(fixture_path("epub-conformance/links.epub"), &source).unwrap();

    let managed = lib.import_managed_file(&source).await.unwrap();

    assert_ne!(managed.id, original.id);
    assert_ne!(managed.content_hash, original.content_hash);
    let unchanged = lib.get(original.id).await.unwrap().unwrap();
    assert_eq!(unchanged.file_path, original.file_path);
    assert_eq!(unchanged.content_hash, original.content_hash);
    assert_eq!(unchanged.storage_kind, StorageKind::Referenced);
}

#[tokio::test]
async fn removing_managed_books_with_a_reused_source_preserves_both_states() {
    let (lib, store, dir) = temp_library().await;
    let source = dir.path().join("book.epub");
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();
    let first = lib.import_managed_file(&source).await.unwrap();
    store
        .set_for_book_async(
            first.id,
            &FileReadingState {
                page: 3,
                location_offset: None,
                zoom: 1.0,
            },
        )
        .await
        .unwrap();
    std::fs::copy(fixture_path("epub-conformance/links.epub"), &source).unwrap();
    let second = lib.import_managed_file(&source).await.unwrap();
    store
        .set_for_book_async(
            second.id,
            &FileReadingState {
                page: 17,
                location_offset: None,
                zoom: 1.0,
            },
        )
        .await
        .unwrap();

    let first_detached = lib.remove(first.id).await.unwrap().unwrap();
    let second_detached = lib.remove(second.id).await.unwrap().unwrap();
    assert_ne!(first_detached, second_detached);
    store
        .set_async(
            &second_detached,
            second.content_hash.as_deref().unwrap(),
            &FileReadingState {
                page: 19,
                location_offset: None,
                zoom: 1.0,
            },
        )
        .await
        .unwrap();

    let states: Vec<(i64, String)> =
        sqlx::query_as("SELECT page, file_path FROM reading_state ORDER BY page")
            .fetch_all(store.pool())
            .await
            .unwrap();
    assert_eq!(states.len(), 2);
    assert_eq!(states[0].0, 3);
    assert_eq!(states[1].0, 19);
    assert_ne!(states[0].1, states[1].1);
}

#[tokio::test]
async fn replacement_book_save_replaces_unowned_state_for_old_content() {
    let (lib, store, dir) = temp_library().await;
    let source = dir.path().join("book.epub");
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();
    let original = lib.import_file(&source).await.unwrap();
    store
        .set_for_book_async(
            original.id,
            &FileReadingState {
                page: 1,
                location_offset: None,
                zoom: 1.0,
            },
        )
        .await
        .unwrap();
    lib.remove(original.id).await.unwrap();
    std::fs::copy(fixture_path("epub-conformance/links.epub"), &source).unwrap();
    let replacement = lib.import_file(&source).await.unwrap();

    store
        .set_async(
            &source,
            replacement.content_hash.as_deref().unwrap(),
            &FileReadingState {
                page: 9,
                location_offset: Some(2),
                zoom: 1.25,
            },
        )
        .await
        .unwrap();

    let state = store
        .get_for_book_async(replacement.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(state.page, 9);
    assert_eq!(state.location_offset, Some(2));
}

#[tokio::test]
async fn relocating_managed_books_preserves_identity_state_and_bookmarks() {
    let (lib, store, dir) = temp_library().await;
    let source = dir.path().join("source.epub");
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();
    let book = lib.import_managed_file(&source).await.unwrap();
    let old_path = PathBuf::from(&book.file_path);
    store
        .set_for_book_async(
            book.id,
            &FileReadingState {
                page: 3,
                location_offset: Some(42),
                zoom: 1.0,
            },
        )
        .await
        .unwrap();
    let bookmarks = BookmarkStore::new(store.pool().clone());
    bookmarks
        .toggle_for_book_at_async(book.id, &old_path, 2, Some(7), None)
        .await
        .unwrap();
    let destination = dir.path().join("external").join("Shosai");

    let changes = lib.relocate_managed_books(&destination).await.unwrap();

    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].book_id, book.id);
    assert!(!old_path.exists());
    assert!(changes[0].new_path.exists());
    let relocated = lib.get(book.id).await.unwrap().unwrap();
    assert_eq!(PathBuf::from(relocated.file_path), changes[0].new_path);
    assert_eq!(
        store
            .get_for_book_async(book.id)
            .await
            .unwrap()
            .unwrap()
            .page,
        3
    );
    let bookmark = bookmarks
        .list_for_book_async(book.id)
        .await
        .unwrap()
        .remove(0);
    assert_eq!(PathBuf::from(bookmark.file_path), changes[0].new_path);
    let bookmark = bookmarks
        .toggle_for_book_at_async(book.id, &old_path, 4, Some(9), None)
        .await
        .unwrap()
        .expect("bookmark should be added using the stable book identity");
    assert_eq!(PathBuf::from(bookmark.file_path), changes[0].new_path);
    assert_eq!(
        path_from_key(
            &store
                .get_pref_async(MANAGED_LIBRARY_DIR_PREFERENCE)
                .await
                .unwrap()
                .unwrap()
        ),
        destination.canonicalize().unwrap()
    );
}

#[tokio::test]
async fn relocation_persists_verified_identity_for_legacy_managed_books() {
    let (lib, store, dir) = temp_library().await;
    let source = dir.path().join("legacy.epub");
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();
    let book = lib.import_managed_file(&source).await.unwrap();
    sqlx::query("UPDATE books SET content_hash = NULL, file_size = NULL WHERE id = ?")
        .bind(book.id)
        .execute(store.pool())
        .await
        .unwrap();

    lib.relocate_managed_books(&dir.path().join("relocated"))
        .await
        .unwrap();

    let relocated = lib.get(book.id).await.unwrap().unwrap();
    assert!(relocated.content_hash.is_some());
    assert!(relocated.file_size.is_some());
}

#[tokio::test]
async fn progress_updates_reject_non_finite_values() {
    let (lib, _, _dir) = temp_library().await;
    assert!(lib.update_progress(1, f64::NAN).await.is_err());
    assert!(
        lib.update_progress_by_path(&PathBuf::from("book.pdf"), f64::INFINITY)
            .await
            .is_err()
    );
}

#[tokio::test]
async fn stale_library_facade_cannot_recreate_the_old_managed_directory() {
    let (lib, store, dir) = temp_library().await;
    let source = dir.path().join("source.epub");
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();
    let managed = lib.import_managed_file(&source).await.unwrap();
    let referenced_source = dir.path().join("referenced.pdf");
    std::fs::copy(fixture_path("sample.pdf"), &referenced_source).unwrap();
    let referenced = lib.import_file(&referenced_source).await.unwrap();
    let old_dir = lib.managed_dir().to_path_buf();
    let destination = dir.path().join("external").join("Shosai");
    lib.relocate_managed_books(&destination).await.unwrap();

    let next = dir.path().join("next.cbz");
    std::fs::copy(fixture_path("sample.cbz"), &next).unwrap();
    let error = lib.import_managed_file(&next).await.unwrap_err();
    assert!(error.to_string().contains("location changed"));
    assert!(lib.import_file(&next).await.is_err());
    let replacement = dir.path().join("replacement.pdf");
    std::fs::copy(&referenced_source, &replacement).unwrap();
    assert!(lib.relink(referenced.id, &replacement).await.is_err());
    assert!(lib.remove(managed.id).await.is_err());
    assert!(!old_dir.exists());
    let current = Library::new(store.pool().clone(), destination.canonicalize().unwrap());
    let retained = current.get(managed.id).await.unwrap().unwrap();
    assert!(path_from_key(&retained.file_path).exists());
    let imported = current.import_managed_file(&next).await.unwrap();
    assert!(path_from_key(&imported.file_path).starts_with(destination.canonicalize().unwrap()));
}

#[cfg(all(unix, not(target_os = "macos")))]
#[tokio::test]
async fn non_unicode_managed_directory_survives_persistence() {
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;

    let (lib, store, dir) = temp_library().await;
    let source = dir.path().join("source.epub");
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();
    lib.import_managed_file(&source).await.unwrap();
    let destination = dir
        .path()
        .join(OsStr::from_bytes(b"external-\x80"))
        .join("Shosai");

    lib.relocate_managed_books(&destination).await.unwrap();

    let stored = store
        .get_pref_async(MANAGED_LIBRARY_DIR_PREFERENCE)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(path_from_key(&stored), destination.canonicalize().unwrap());
}

#[tokio::test]
async fn managed_import_uses_the_source_filename_for_fallback_metadata() {
    let (lib, _, dir) = temp_library().await;
    let source = dir.path().join("My Comic.cbz");
    std::fs::copy(fixture_path("sample.cbz"), &source).unwrap();

    let book = lib.import_managed_file(&source).await.unwrap();

    assert_eq!(book.title, "My Comic");
}

#[tokio::test]
async fn relink_preserves_stable_identity_reading_state_and_bookmarks() {
    let (lib, store, dir) = temp_library().await;
    let original = dir.path().join("original.epub");
    let replacement = dir.path().join("moved.epub");
    std::fs::copy(fixture_path("sample.epub"), &original).unwrap();
    let book = lib.import_file(&original).await.unwrap();
    store
        .set_for_book_async(
            book.id,
            &FileReadingState {
                page: 3,
                location_offset: Some(42),
                zoom: 1.0,
            },
        )
        .await
        .unwrap();
    let bookmarks = BookmarkStore::new(store.pool().clone());
    bookmarks
        .toggle_for_book_at_async(book.id, &original, 2, Some(7), None)
        .await
        .unwrap();
    std::fs::rename(&original, &replacement).unwrap();

    let relinked = lib.relink(book.id, &replacement).await.unwrap();

    assert_eq!(relinked.id, book.id);
    assert_eq!(relinked.storage_kind, StorageKind::Referenced);
    assert_eq!(
        PathBuf::from(relinked.file_path),
        replacement.canonicalize().unwrap()
    );
    assert_eq!(
        store
            .get_for_book_async(book.id)
            .await
            .unwrap()
            .unwrap()
            .page,
        3
    );
    assert_eq!(
        bookmarks.list_for_book_async(book.id).await.unwrap().len(),
        1
    );
}

#[tokio::test]
async fn relink_rejects_a_different_book() {
    let (lib, _, dir) = temp_library().await;
    let original = dir.path().join("original.epub");
    std::fs::copy(fixture_path("sample.epub"), &original).unwrap();
    let book = lib.import_file(&original).await.unwrap();

    let different_epub = fixture_path("epub-conformance/table.epub");
    let result = lib.relink(book.id, &different_epub).await;

    assert!(result.is_err());
    assert_eq!(
        lib.get(book.id).await.unwrap().unwrap().file_path,
        book.file_path
    );
}

#[tokio::test]
async fn relink_refuses_to_guess_the_identity_of_an_unfingerprinted_book() {
    let (lib, store, dir) = temp_library().await;
    let original = dir.path().join("legacy.epub");
    std::fs::copy(fixture_path("sample.epub"), &original).unwrap();
    let book = lib.import_file(&original).await.unwrap();
    sqlx::query("UPDATE books SET content_hash = NULL, file_size = NULL WHERE id = ?")
        .bind(book.id)
        .execute(store.pool())
        .await
        .unwrap();
    std::fs::remove_file(original).unwrap();

    let result = lib
        .relink(book.id, &fixture_path("epub-conformance/table.epub"))
        .await;

    assert!(result.is_err());
    assert!(format!("{:#}", result.unwrap_err()).contains("cannot verify"));
}

#[tokio::test]
async fn relink_merges_state_and_bookmark_aliases_at_the_replacement_path() {
    let (lib, store, dir) = temp_library().await;
    let original = dir.path().join("original.epub");
    let replacement = dir.path().join("replacement.epub");
    std::fs::copy(fixture_path("sample.epub"), &original).unwrap();
    std::fs::copy(fixture_path("sample.epub"), &replacement).unwrap();
    let book = lib.import_file(&original).await.unwrap();
    // Create the replacement alias first so its rowid is older, then update it last.
    store
        .set_async(
            &replacement,
            book.content_hash.as_deref().unwrap(),
            &FileReadingState {
                page: 0,
                location_offset: None,
                zoom: 1.0,
            },
        )
        .await
        .unwrap();
    store
        .set_for_book_async(
            book.id,
            &FileReadingState {
                page: 2,
                location_offset: None,
                zoom: 1.0,
            },
        )
        .await
        .unwrap();
    sqlx::query("UPDATE reading_state SET updated_at = '2026-01-01' WHERE book_id = ?")
        .bind(book.id)
        .execute(store.pool())
        .await
        .unwrap();
    store
        .set_async(
            &replacement,
            book.content_hash.as_deref().unwrap(),
            &FileReadingState {
                page: 8,
                location_offset: Some(12),
                zoom: 1.25,
            },
        )
        .await
        .unwrap();
    sqlx::query("UPDATE reading_state SET updated_at = '2026-01-01' WHERE file_path = ?")
        .bind(
            replacement
                .canonicalize()
                .unwrap()
                .to_string_lossy()
                .as_ref(),
        )
        .execute(store.pool())
        .await
        .unwrap();

    let bookmarks = BookmarkStore::new(store.pool().clone());
    bookmarks
        .toggle_for_book_at_async(book.id, &original, 3, Some(7), None)
        .await
        .unwrap();
    bookmarks
        .add_at_async(
            &replacement,
            book.content_hash.as_deref().unwrap(),
            3,
            Some(7),
            None,
            None,
            "yellow",
        )
        .await
        .unwrap();
    bookmarks
        .add_at_async(
            &replacement,
            book.content_hash.as_deref().unwrap(),
            6,
            None,
            Some("Other"),
            Some("note"),
            "blue",
        )
        .await
        .unwrap();

    lib.relink(book.id, &replacement).await.unwrap();

    let state = store.get_for_book_async(book.id).await.unwrap().unwrap();
    assert_eq!((state.page, state.location_offset), (8, Some(12)));
    let merged = bookmarks.list_for_book_async(book.id).await.unwrap();
    assert_eq!(merged.len(), 2);
    let replacement = replacement.canonicalize().unwrap();
    let replacement_str = replacement.to_string_lossy();
    assert!(
        merged
            .iter()
            .all(|bookmark| bookmark.file_path == replacement_str)
    );
    store
        .set_for_book_async(
            book.id,
            &FileReadingState {
                page: 9,
                location_offset: Some(13),
                zoom: 1.0,
            },
        )
        .await
        .unwrap();
}

#[tokio::test]
async fn bookmark_alias_merge_keeps_newest_row_and_all_of_its_metadata() {
    let (lib, store, dir) = temp_library().await;
    let original = dir.path().join("original.epub");
    let replacement = dir.path().join("replacement.epub");
    std::fs::copy(fixture_path("sample.epub"), &original).unwrap();
    std::fs::copy(fixture_path("sample.epub"), &replacement).unwrap();
    let book = lib.import_file(&original).await.unwrap();
    let original_key = book.file_path.clone();
    let replacement_key = replacement
        .canonicalize()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let stable_id: i64 = sqlx::query_scalar(
        "INSERT INTO bookmarks
         (file_path, content_hash, book_id, page, location_offset, title, note, color, created_at)
         VALUES (?, ?, ?, 4, 9, 'older title', 'same note', 'yellow', '2026-01-01')
         RETURNING id",
    )
    .bind(&original_key)
    .bind(book.content_hash.as_deref().unwrap())
    .bind(book.id)
    .fetch_one(store.pool())
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO bookmarks
         (file_path, content_hash, page, location_offset, title, note, color, created_at)
         VALUES (?, ?, 4, 9, 'winner title', 'same note', 'blue', '2026-02-01')",
    )
    .bind(&replacement_key)
    .bind(book.content_hash.as_deref().unwrap())
    .execute(store.pool())
    .await
    .unwrap();

    lib.relink(book.id, &replacement).await.unwrap();

    let row = sqlx::query("SELECT id, title, color, created_at FROM bookmarks WHERE book_id = ?")
        .bind(book.id)
        .fetch_one(store.pool())
        .await
        .unwrap();
    use sqlx::Row;
    assert_eq!(row.get::<i64, _>("id"), stable_id);
    assert_eq!(row.get::<String, _>("title"), "winner title");
    assert_eq!(row.get::<String, _>("color"), "blue");
    assert_eq!(row.get::<String, _>("created_at"), "2026-02-01");
}

#[tokio::test]
async fn managed_import_repairs_a_corrupt_existing_destination() {
    let (lib, _, dir) = temp_library().await;
    let source = dir.path().join("source.epub");
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();
    let book = lib.import_managed_file(&source).await.unwrap();
    std::fs::write(&book.file_path, b"corrupt").unwrap();

    let imported = lib.import_managed_file(&source).await.unwrap();

    assert_eq!(imported.id, book.id);
    assert_eq!(
        std::fs::read(imported.file_path).unwrap(),
        std::fs::read(source).unwrap()
    );
}

#[tokio::test]
async fn concurrent_identical_managed_imports_return_the_same_book() {
    let (lib, _, dir) = temp_library().await;
    let first = dir.path().join("first.epub");
    let second = dir.path().join("second.epub");
    let third = dir.path().join("third.epub");
    let fourth = dir.path().join("fourth.epub");
    std::fs::copy(fixture_path("sample.epub"), &first).unwrap();
    std::fs::copy(fixture_path("sample.epub"), &second).unwrap();
    std::fs::copy(fixture_path("sample.epub"), &third).unwrap();
    std::fs::copy(fixture_path("sample.epub"), &fourth).unwrap();

    let results = tokio::join!(
        lib.import_managed_file(&first),
        lib.import_managed_file(&second),
        lib.import_managed_file(&third),
        lib.import_managed_file(&fourth),
    );

    let ids = [results.0, results.1, results.2, results.3].map(|result| result.unwrap().id);
    assert!(ids.iter().all(|id| *id == ids[0]));
    assert_eq!(lib.list_all().await.unwrap().len(), 1);
}

#[tokio::test]
async fn removing_a_managed_book_deletes_its_private_copy() {
    let (lib, store, dir) = temp_library().await;
    let source = dir.path().join("source.epub");
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();
    let book = lib.import_managed_file(&source).await.unwrap();
    let managed_path = PathBuf::from(&book.file_path);
    let content_hash = book.content_hash.as_deref().unwrap();
    store
        .set_for_book_async(
            book.id,
            &FileReadingState {
                page: 3,
                location_offset: Some(42),
                zoom: 1.0,
            },
        )
        .await
        .unwrap();
    let bookmarks = BookmarkStore::new(store.pool().clone());
    bookmarks
        .toggle_for_book_at_async(book.id, &managed_path, 2, Some(7), None)
        .await
        .unwrap();

    let detached_path = lib.remove(book.id).await.unwrap();

    assert_eq!(
        detached_path.as_deref(),
        Some(source.canonicalize().unwrap().as_path())
    );
    assert!(!managed_path.exists());
    assert!(source.exists());
    assert_eq!(
        store
            .get_async(&source, content_hash)
            .await
            .unwrap()
            .unwrap()
            .page,
        3
    );
    let bookmark = bookmarks
        .list_for_file_async(&source, content_hash)
        .await
        .unwrap()
        .remove(0);
    assert_eq!(
        path_from_key(&bookmark.file_path),
        source.canonicalize().unwrap()
    );
}

#[tokio::test]
async fn removing_a_referenced_book_never_deletes_the_original() {
    let (lib, _, dir) = temp_library().await;
    let source = dir.path().join("source.epub");
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();
    let book = lib.import_file(&source).await.unwrap();

    lib.remove(book.id).await.unwrap();

    assert!(source.exists());
}

async fn assert_captured_path_mutations_follow_import(managed: bool) {
    let (library, store, dir) = temp_library().await;
    let source = dir.path().join(if managed {
        "managed-source.epub"
    } else {
        "referenced.epub"
    });
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();
    let hash = format!("{:x}", Sha256::digest(std::fs::read(&source).unwrap()));
    let captured_save = StateSave {
        book_id: None,
        path: source.clone(),
        content_hash: Some(hash.clone()),
        reading: FileReadingState {
            page: 11,
            location_offset: Some(29),
            zoom: 1.25,
        },
    };
    let captured_bookmark = (source.clone(), hash.clone(), 7, Some(13));

    let book = if managed {
        library.import_managed_file(&source).await.unwrap()
    } else {
        library.import_file(&source).await.unwrap()
    };

    let writer = start_state_writer(store.clone());
    writer
        .send(StateWriterMessage::Save(captured_save))
        .unwrap();
    // Immediate close must drain rather than retain and retry the promoted path save.
    writer.quiesce_and_shutdown().await.unwrap();

    let bookmarks = BookmarkStore::new(store.pool().clone());
    bookmarks
        .toggle_at_async(
            &captured_bookmark.0,
            &captured_bookmark.1,
            captured_bookmark.2,
            captured_bookmark.3,
            None,
        )
        .await
        .unwrap();

    let reading = store.get_for_book_async(book.id).await.unwrap().unwrap();
    assert_eq!(reading.page, 11);
    assert_eq!(reading.location_offset, Some(29));
    let stored = bookmarks.list_for_book_async(book.id).await.unwrap();
    assert_eq!(stored.len(), 1);
    assert_eq!(stored[0].book_id, Some(book.id));
    assert_eq!(stored[0].page, 7);
    assert_eq!(stored[0].file_path, book.file_path);
    let source_reading = store.get_async(&source, &hash).await.unwrap().unwrap();
    assert_eq!(source_reading.page, 11);
    let source_bookmarks = bookmarks.list_for_file_async(&source, &hash).await.unwrap();
    assert_eq!(source_bookmarks.len(), 1);
    assert_eq!(source_bookmarks[0].book_id, Some(book.id));
    let stranded_state: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM reading_state WHERE book_id IS NULL AND content_hash = ?",
    )
    .bind(&hash)
    .fetch_one(store.pool())
    .await
    .unwrap();
    let stranded_bookmarks: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM bookmarks WHERE book_id IS NULL AND content_hash = ?",
    )
    .bind(&hash)
    .fetch_one(store.pool())
    .await
    .unwrap();
    assert_eq!((stranded_state, stranded_bookmarks), (0, 0));
}

#[tokio::test]
async fn referenced_import_claims_captured_path_mutations_and_immediate_close_drains() {
    assert_captured_path_mutations_follow_import(false).await;
}

#[tokio::test]
async fn managed_import_claims_captured_source_mutations_and_immediate_close_drains() {
    assert_captured_path_mutations_follow_import(true).await;
}
