use shosai_core::bookmarks::BookmarkStore;
use shosai_core::library::{BookFormat, Library, StorageKind};
use shosai_core::reading_state::{FileReadingState, ReadingStateStore};
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

    let books = lib.import_directory(&import_dir).await.unwrap();
    assert_eq!(books.len(), 2);
}

#[tokio::test]
async fn linked_directory_keeps_books_in_their_original_locations() {
    let (lib, _, dir) = temp_library().await;
    let import_dir = dir.path().join("imports");
    std::fs::create_dir_all(&import_dir).unwrap();
    let source = import_dir.join("book.epub");
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();

    let books = lib.link_directory(&import_dir).await.unwrap();

    assert_eq!(books.len(), 1);
    assert_eq!(books[0].storage_kind, StorageKind::Referenced);
    assert_eq!(
        PathBuf::from(&books[0].file_path),
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
            &original,
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
    assert_eq!(store.get_for_book_async(book.id).await.unwrap().page, 3);
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
    store
        .set_for_book_async(
            book.id,
            &original,
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
            &FileReadingState {
                page: 8,
                location_offset: Some(12),
                zoom: 1.25,
            },
        )
        .await
        .unwrap();
    sqlx::query("UPDATE reading_state SET updated_at = '2026-02-01' WHERE file_path = ?")
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
        .add_at_async(&replacement, 3, Some(7), None, None, "yellow")
        .await
        .unwrap();
    bookmarks
        .add_at_async(&replacement, 6, None, Some("Other"), Some("note"), "blue")
        .await
        .unwrap();

    lib.relink(book.id, &replacement).await.unwrap();

    let state = store.get_for_book_async(book.id).await.unwrap();
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
            &replacement,
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
    std::fs::copy(fixture_path("sample.epub"), &first).unwrap();
    std::fs::copy(fixture_path("sample.epub"), &second).unwrap();

    let (first_result, second_result) = tokio::join!(
        lib.import_managed_file(&first),
        lib.import_managed_file(&second)
    );

    assert_eq!(first_result.unwrap().id, second_result.unwrap().id);
    assert_eq!(lib.list_all().await.unwrap().len(), 1);
}

#[tokio::test]
async fn removing_a_managed_book_deletes_its_private_copy() {
    let (lib, _, dir) = temp_library().await;
    let source = dir.path().join("source.epub");
    std::fs::copy(fixture_path("sample.epub"), &source).unwrap();
    let book = lib.import_managed_file(&source).await.unwrap();
    let managed_path = PathBuf::from(&book.file_path);

    lib.remove(book.id).await.unwrap();

    assert!(!managed_path.exists());
    assert!(source.exists());
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
