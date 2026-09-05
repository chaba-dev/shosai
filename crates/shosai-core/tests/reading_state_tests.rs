use shosai_core::reading_state::{FileReadingState, ReadingStateStore};
use sqlx::sqlite::{SqliteConnectOptions, SqlitePool};
use std::borrow::Cow;
use std::path::PathBuf;
use tempfile::TempDir;

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");
const CONTENT_HASH: &str = "0000000000000000000000000000000000000000000000000000000000000000";

/// Each test gets its own temporary directory (and therefore its own database).
/// The directory is cleaned up automatically when `TempDir` is dropped.
async fn temp_store() -> (ReadingStateStore, TempDir) {
    let dir = TempDir::new().unwrap();
    let db_path = dir.path().join("shosai.db");
    let store = ReadingStateStore::open_at_async(&db_path).await.unwrap();
    (store, dir)
}

#[tokio::test]
async fn platform_host_can_inject_its_application_data_directory() {
    let directory = TempDir::new().unwrap();
    let data = directory.path().join("mobile-app-support");

    let store = ReadingStateStore::open_in_data_directory_async(&data)
        .await
        .unwrap();

    assert_eq!(store.managed_books_dir(), data.join("books"));
    assert!(data.join("shosai.db").exists());
}

// ---------------------------------------------------------------------------
// Basic CRUD
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_get_nonexistent_returns_none() {
    let (store, _dir) = temp_store().await;
    assert!(
        store
            .get_async(&PathBuf::from("/no/such/file.pdf"), CONTENT_HASH)
            .await
            .unwrap()
            .is_none()
    );
}

#[tokio::test]
async fn malformed_reading_state_rows_return_an_error() {
    let (store, _dir) = temp_store().await;
    let path = PathBuf::from("/books/malformed.epub");
    sqlx::query(
        "INSERT INTO reading_state (file_path, content_hash, page, zoom)
         VALUES (?, ?, -1, 1.0)",
    )
    .bind(path.to_string_lossy().as_ref())
    .bind(CONTENT_HASH)
    .execute(store.pool())
    .await
    .unwrap();

    assert!(store.get_async(&path, CONTENT_HASH).await.is_err());
}

#[tokio::test]
async fn fingerprint_backfill_returns_an_error_for_malformed_legacy_rows() {
    let (store, _dir) = temp_store().await;
    sqlx::query(
        "INSERT INTO books (title, format, file_path)
         VALUES ('Malformed', 'unknown', '/books/malformed')",
    )
    .execute(store.pool())
    .await
    .unwrap();

    assert!(store.backfill_missing_fingerprints().await.is_err());
}

#[cfg(unix)]
#[tokio::test]
async fn non_unicode_paths_have_distinct_reading_state_keys() {
    use std::ffi::OsString;
    use std::os::unix::ffi::OsStringExt;

    let (store, directory) = temp_store().await;
    let first = directory
        .path()
        .join(OsString::from_vec(b"book-\x80.epub".to_vec()));
    let second = directory
        .path()
        .join(OsString::from_vec(b"book-\x81.epub".to_vec()));
    store
        .set_async(
            &first,
            CONTENT_HASH,
            &FileReadingState {
                page: 1,
                location_offset: Some(10),
                zoom: 1.0,
            },
        )
        .await
        .unwrap();
    store
        .set_async(
            &second,
            CONTENT_HASH,
            &FileReadingState {
                page: 2,
                location_offset: Some(20),
                zoom: 1.0,
            },
        )
        .await
        .unwrap();

    assert_eq!(
        store
            .get_async(&first, CONTENT_HASH)
            .await
            .unwrap()
            .unwrap()
            .page,
        1
    );
    assert_eq!(
        store
            .get_async(&second, CONTENT_HASH)
            .await
            .unwrap()
            .unwrap()
            .page,
        2
    );
}

#[tokio::test]
async fn test_set_then_get() {
    let (store, _dir) = temp_store().await;
    let path = PathBuf::from("/books/rust.pdf");

    store
        .set_async(
            &path,
            CONTENT_HASH,
            &FileReadingState {
                page: 5,
                location_offset: None,
                zoom: 1.5,
            },
        )
        .await
        .unwrap();

    let state = store
        .get_async(&path, CONTENT_HASH)
        .await
        .unwrap()
        .expect("should exist after set");
    assert_eq!(state.page, 5);
    assert!((state.zoom - 1.5).abs() < f32::EPSILON);
}

#[tokio::test]
async fn path_state_is_restored_only_for_matching_content() {
    let (store, _dir) = temp_store().await;
    let path = PathBuf::from("/books/replaced.epub");
    store
        .set_async(
            &path,
            CONTENT_HASH,
            &FileReadingState {
                page: 5,
                location_offset: None,
                zoom: 1.0,
            },
        )
        .await
        .unwrap();

    assert!(
        store
            .get_async(
                &path,
                "1111111111111111111111111111111111111111111111111111111111111111",
            )
            .await
            .unwrap()
            .is_none()
    );
}

#[tokio::test]
async fn reading_state_queries_report_database_failures() {
    let (store, _dir) = temp_store().await;
    store.pool().close().await;

    assert!(
        store
            .get_async(PathBuf::from("book.epub").as_path(), CONTENT_HASH)
            .await
            .is_err()
    );
    assert!(store.get_for_book_async(1).await.is_err());
}

#[tokio::test]
async fn reading_state_writes_reject_unrepresentable_values() {
    let (store, _dir) = temp_store().await;
    let invalid_zoom = FileReadingState {
        page: 0,
        location_offset: None,
        zoom: f32::NAN,
    };

    assert!(
        store
            .set_async(
                PathBuf::from("book.epub").as_path(),
                CONTENT_HASH,
                &invalid_zoom,
            )
            .await
            .is_err()
    );

    if usize::BITS > 63 {
        let invalid_page = FileReadingState {
            page: usize::MAX,
            location_offset: None,
            zoom: 1.0,
        };
        assert!(
            store
                .set_async(
                    PathBuf::from("book.epub").as_path(),
                    CONTENT_HASH,
                    &invalid_page,
                )
                .await
                .is_err()
        );
    }
}

#[tokio::test]
async fn test_epub_character_offset_persists() {
    let (store, _dir) = temp_store().await;
    let path = PathBuf::from("/books/example.epub");

    store
        .set_async(
            &path,
            CONTENT_HASH,
            &FileReadingState {
                page: 4,
                location_offset: Some(1_234),
                zoom: 1.0,
            },
        )
        .await
        .unwrap();

    let state = store.get_async(&path, CONTENT_HASH).await.unwrap().unwrap();
    assert_eq!(state.page, 4);
    assert_eq!(state.location_offset, Some(1_234));
}

#[tokio::test]
async fn test_upsert_overwrites() {
    let (store, _dir) = temp_store().await;
    let path = PathBuf::from("/books/overwrite.pdf");

    store
        .set_async(
            &path,
            CONTENT_HASH,
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
            &path,
            CONTENT_HASH,
            &FileReadingState {
                page: 42,
                location_offset: None,
                zoom: 3.0,
            },
        )
        .await
        .unwrap();

    let state = store.get_async(&path, CONTENT_HASH).await.unwrap().unwrap();
    assert_eq!(state.page, 42);
    assert!((state.zoom - 3.0).abs() < f32::EPSILON);
}

#[tokio::test]
async fn test_multiple_files_independent() {
    let (store, _dir) = temp_store().await;
    let a = PathBuf::from("/books/a.pdf");
    let b = PathBuf::from("/books/b.pdf");

    store
        .set_async(
            &a,
            CONTENT_HASH,
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
            &b,
            CONTENT_HASH,
            &FileReadingState {
                page: 99,
                location_offset: None,
                zoom: 2.5,
            },
        )
        .await
        .unwrap();

    let sa = store.get_async(&a, CONTENT_HASH).await.unwrap().unwrap();
    assert_eq!(sa.page, 1);
    assert!((sa.zoom - 1.0).abs() < f32::EPSILON);

    let sb = store.get_async(&b, CONTENT_HASH).await.unwrap().unwrap();
    assert_eq!(sb.page, 99);
    assert!((sb.zoom - 2.5).abs() < f32::EPSILON);
}

#[tokio::test]
async fn test_updating_one_file_does_not_affect_another() {
    let (store, _dir) = temp_store().await;
    let a = PathBuf::from("/books/a.pdf");
    let b = PathBuf::from("/books/b.pdf");

    store
        .set_async(
            &a,
            CONTENT_HASH,
            &FileReadingState {
                page: 10,
                location_offset: None,
                zoom: 1.0,
            },
        )
        .await
        .unwrap();
    store
        .set_async(
            &b,
            CONTENT_HASH,
            &FileReadingState {
                page: 20,
                location_offset: None,
                zoom: 2.0,
            },
        )
        .await
        .unwrap();

    // Update only b
    store
        .set_async(
            &b,
            CONTENT_HASH,
            &FileReadingState {
                page: 50,
                location_offset: None,
                zoom: 4.0,
            },
        )
        .await
        .unwrap();

    // a should be untouched
    let sa = store.get_async(&a, CONTENT_HASH).await.unwrap().unwrap();
    assert_eq!(sa.page, 10);

    let sb = store.get_async(&b, CONTENT_HASH).await.unwrap().unwrap();
    assert_eq!(sb.page, 50);
    assert!((sb.zoom - 4.0).abs() < f32::EPSILON);
}

// ---------------------------------------------------------------------------
// Persistence across store instances
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_data_persists_across_opens() {
    let dir = TempDir::new().unwrap();
    let db_path = dir.path().join("shosai.db");
    let path = PathBuf::from("/books/persist.pdf");

    // Write with first instance
    {
        let store = ReadingStateStore::open_at_async(&db_path).await.unwrap();
        store
            .set_async(
                &path,
                CONTENT_HASH,
                &FileReadingState {
                    page: 42,
                    location_offset: None,
                    zoom: 2.0,
                },
            )
            .await
            .unwrap();
    }

    // Read with a fresh instance
    {
        let store = ReadingStateStore::open_at_async(&db_path).await.unwrap();
        let state = store
            .get_async(&path, CONTENT_HASH)
            .await
            .expect("query should succeed")
            .expect("should persist");
        assert_eq!(state.page, 42);
        assert!((state.zoom - 2.0).abs() < f32::EPSILON);
    }
}

#[tokio::test]
async fn test_preferences_persist_across_opens() {
    let dir = TempDir::new().unwrap();
    let db_path = dir.path().join("shosai.db");

    {
        let store = ReadingStateStore::open_at_async(&db_path).await.unwrap();
        store
            .set_pref_int_async("library.cards_per_row", 6)
            .await
            .unwrap();
        store.set_pref_async("language", "ja").await.unwrap();
    }

    {
        let store = ReadingStateStore::open_at_async(&db_path).await.unwrap();
        let value = store.get_pref_int_async("library.cards_per_row").await;
        assert_eq!(value, Some(6));
        assert_eq!(
            store.get_pref_async("language").await.as_deref(),
            Some("ja")
        );
    }
}

#[tokio::test]
async fn all_preferences_are_loaded_together() {
    let (store, _dir) = temp_store().await;
    store.set_pref_async("first", "one").await.unwrap();
    store.set_pref_async("second", "2").await.unwrap();

    let preferences = store.get_prefs_async().await;

    assert_eq!(preferences.get("first").map(String::as_str), Some("one"));
    assert_eq!(preferences.get("second").map(String::as_str), Some("2"));
}

#[tokio::test]
async fn test_multiple_preferences_are_saved_atomically() {
    let dir = TempDir::new().unwrap();
    let db_path = dir.path().join("shosai.db");
    let store = ReadingStateStore::open_at_async(&db_path).await.unwrap();

    store
        .set_pref_ints_async(&[("window.width", 900), ("window.height", 700)])
        .await
        .unwrap();

    assert_eq!(store.get_pref_int_async("window.width").await, Some(900));
    assert_eq!(store.get_pref_int_async("window.height").await, Some(700));
}

#[tokio::test]
async fn test_migrations_are_idempotent() {
    let dir = TempDir::new().unwrap();
    let db_path = dir.path().join("shosai.db");
    let path = PathBuf::from("/books/idempotent.pdf");

    // Open and write
    let store = ReadingStateStore::open_at_async(&db_path).await.unwrap();
    store
        .set_async(
            &path,
            CONTENT_HASH,
            &FileReadingState {
                page: 7,
                location_offset: None,
                zoom: 1.25,
            },
        )
        .await
        .unwrap();
    drop(store);

    // Open again — migrations run a second time but should not destroy data
    let store = ReadingStateStore::open_at_async(&db_path).await.unwrap();
    let state = store
        .get_async(&path, CONTENT_HASH)
        .await
        .unwrap()
        .expect("data should survive re-migration");
    assert_eq!(state.page, 7);
    assert!((state.zoom - 1.25).abs() < f32::EPSILON);
}

#[tokio::test]
async fn revision_migration_orders_legacy_rows_by_last_update() {
    let dir = TempDir::new().unwrap();
    let db_path = dir.path().join("shosai.db");
    let options = SqliteConnectOptions::new()
        .filename(&db_path)
        .create_if_missing(true);
    let pool = SqlitePool::connect_with(options).await.unwrap();
    let v8_migrator = sqlx::migrate::Migrator {
        migrations: Cow::Owned(MIGRATOR.migrations[..8].to_vec()),
        ..sqlx::migrate::Migrator::DEFAULT
    };
    v8_migrator.run(&pool).await.unwrap();
    sqlx::query(
        "INSERT INTO reading_state (file_path, page, zoom, updated_at)
         VALUES ('older-rowid', 1, 1.0, '2026-02-01 00:00:00'),
                ('newer-rowid', 2, 1.0, '2026-01-01 00:00:00')",
    )
    .execute(&pool)
    .await
    .unwrap();
    pool.close().await;

    let store = ReadingStateStore::open_at_async(&db_path).await.unwrap();
    let revisions: Vec<(String, i64)> =
        sqlx::query_as("SELECT file_path, revision FROM reading_state ORDER BY revision")
            .fetch_all(store.pool())
            .await
            .unwrap();

    assert_eq!(
        revisions,
        vec![("newer-rowid".to_owned(), 1), ("older-rowid".to_owned(), 2),]
    );
}

#[tokio::test]
async fn legacy_fingerprints_can_be_backfilled_after_migration() {
    let dir = TempDir::new().unwrap();
    let db_path = dir.path().join("shosai.db");
    let reachable = dir.path().join("reachable.epub");
    let missing = dir.path().join("missing.epub");
    std::fs::copy(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/sample.epub"),
        &reachable,
    )
    .unwrap();

    let options = SqliteConnectOptions::new()
        .filename(&db_path)
        .create_if_missing(true);
    let pool = SqlitePool::connect_with(options).await.unwrap();
    let v5_migrator = sqlx::migrate::Migrator {
        migrations: Cow::Owned(MIGRATOR.migrations[..5].to_vec()),
        ..sqlx::migrate::Migrator::DEFAULT
    };
    v5_migrator.run(&pool).await.unwrap();
    for path in [&reachable, &missing] {
        sqlx::query("INSERT INTO books (title, format, file_path) VALUES ('Legacy', 'epub', ?)")
            .bind(path.to_string_lossy().as_ref())
            .execute(&pool)
            .await
            .unwrap();
    }
    pool.close().await;

    let store = ReadingStateStore::open_at_async_deferred_backfill(&db_path)
        .await
        .unwrap();
    let pending: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM books WHERE content_hash IS NULL")
        .fetch_one(store.pool())
        .await
        .unwrap();
    assert_eq!(pending, 2);

    store.backfill_missing_fingerprints().await.unwrap();
    let rows: Vec<(String, Option<String>, Option<i64>)> =
        sqlx::query_as("SELECT file_path, content_hash, file_size FROM books ORDER BY id")
            .fetch_all(store.pool())
            .await
            .unwrap();

    assert_eq!(rows.len(), 2);
    assert!(rows[0].1.is_some());
    assert_eq!(
        rows[0].2,
        Some(std::fs::metadata(reachable).unwrap().len() as i64)
    );
    assert_eq!(rows[1].1, None);
    assert_eq!(rows[1].2, None);
}

#[tokio::test]
async fn legacy_fingerprint_backfill_processes_multiple_bounded_pages() {
    let (store, dir) = temp_store().await;
    for index in 0..105 {
        let path = dir.path().join(format!("legacy-{index}.epub"));
        std::fs::write(&path, format!("legacy-{index}")).unwrap();
        sqlx::query(
            "INSERT INTO books (title, format, file_path, content_hash)
             VALUES ('Legacy', 'epub', ?, NULL)",
        )
        .bind(path.to_string_lossy().as_ref())
        .execute(store.pool())
        .await
        .unwrap();
    }

    store.backfill_missing_fingerprints().await.unwrap();

    let pending: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM books WHERE content_hash IS NULL")
        .fetch_one(store.pool())
        .await
        .unwrap();
    assert_eq!(pending, 0);
}

#[tokio::test]
async fn legacy_fingerprint_backfill_uses_the_stored_format_limit() {
    let (store, dir) = temp_store().await;
    let path = dir.path().join("legacy-without-supported-extension.bin");
    std::fs::File::create(&path)
        .unwrap()
        .set_len(shosai_core::epub::EpubLimits::default().max_input_bytes + 1)
        .unwrap();
    sqlx::query(
        "INSERT INTO books (title, format, file_path, content_hash)
         VALUES ('Legacy', 'epub', ?, NULL)",
    )
    .bind(path.to_string_lossy().as_ref())
    .execute(store.pool())
    .await
    .unwrap();

    store.backfill_missing_fingerprints().await.unwrap();

    let fingerprint: Option<String> = sqlx::query_scalar("SELECT content_hash FROM books")
        .fetch_one(store.pool())
        .await
        .unwrap();
    assert_eq!(fingerprint, None);
}

#[tokio::test]
async fn stable_save_replaces_a_path_only_alias() {
    let (store, _dir) = temp_store().await;
    let path = PathBuf::from("/books/relinked.epub");
    let book_id: i64 = sqlx::query_scalar(
        "INSERT INTO books (title, format, file_path, content_hash)
         VALUES ('Book', 'epub', '/books/relinked.epub', ?)
         RETURNING id",
    )
    .bind(CONTENT_HASH)
    .fetch_one(store.pool())
    .await
    .unwrap();
    store
        .set_async(
            &path,
            CONTENT_HASH,
            &FileReadingState {
                page: 1,
                location_offset: None,
                zoom: 1.0,
            },
        )
        .await
        .unwrap();

    store
        .set_for_book_async(
            book_id,
            &FileReadingState {
                page: 9,
                location_offset: Some(3),
                zoom: 1.5,
            },
        )
        .await
        .unwrap();

    let state = store.get_for_book_async(book_id).await.unwrap().unwrap();
    assert_eq!(state.page, 9);
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM reading_state WHERE file_path = ?")
        .bind(path.to_string_lossy().as_ref())
        .fetch_one(store.pool())
        .await
        .unwrap();
    assert_eq!(count, 1);
}

#[tokio::test]
async fn stable_save_does_not_overwrite_a_row_owned_by_another_book() {
    let (store, _dir) = temp_store().await;
    let target_id: i64 = sqlx::query_scalar(
        "INSERT INTO books (title, format, file_path, content_hash)
         VALUES ('Target', 'epub', '/books/target.epub', ?) RETURNING id",
    )
    .bind(CONTENT_HASH)
    .fetch_one(store.pool())
    .await
    .unwrap();
    let other_id: i64 = sqlx::query_scalar(
        "INSERT INTO books (title, format, file_path, content_hash)
         VALUES ('Other', 'epub', '/books/other.epub', ?) RETURNING id",
    )
    .bind("1111111111111111111111111111111111111111111111111111111111111111")
    .fetch_one(store.pool())
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO reading_state (file_path, content_hash, book_id, page, zoom)
         VALUES ('/books/target.epub', ?, ?, 4, 1.0)",
    )
    .bind("1111111111111111111111111111111111111111111111111111111111111111")
    .bind(other_id)
    .execute(store.pool())
    .await
    .unwrap();

    let result = store
        .set_for_book_async(
            target_id,
            &FileReadingState {
                page: 9,
                location_offset: None,
                zoom: 1.0,
            },
        )
        .await;

    assert!(result.is_err());
    let owner: i64 = sqlx::query_scalar(
        "SELECT book_id FROM reading_state WHERE file_path = '/books/target.epub'",
    )
    .fetch_one(store.pool())
    .await
    .unwrap();
    assert_eq!(owner, other_id);
}

// ---------------------------------------------------------------------------
// Edge cases
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_page_zero_and_default_zoom() {
    let (store, _dir) = temp_store().await;
    let path = PathBuf::from("/books/start.pdf");

    store
        .set_async(
            &path,
            CONTENT_HASH,
            &FileReadingState {
                page: 0,
                location_offset: None,
                zoom: 1.0,
            },
        )
        .await
        .unwrap();

    let state = store.get_async(&path, CONTENT_HASH).await.unwrap().unwrap();
    assert_eq!(state.page, 0);
    assert!((state.zoom - 1.0).abs() < f32::EPSILON);
}

#[tokio::test]
async fn test_large_page_number() {
    let (store, _dir) = temp_store().await;
    let path = PathBuf::from("/books/big.pdf");

    store
        .set_async(
            &path,
            CONTENT_HASH,
            &FileReadingState {
                page: 999_999,
                location_offset: None,
                zoom: 5.0,
            },
        )
        .await
        .unwrap();

    let state = store.get_async(&path, CONTENT_HASH).await.unwrap().unwrap();
    assert_eq!(state.page, 999_999);
    assert!((state.zoom - 5.0).abs() < f32::EPSILON);
}

#[tokio::test]
async fn test_small_zoom_value() {
    let (store, _dir) = temp_store().await;
    let path = PathBuf::from("/books/tiny.pdf");

    store
        .set_async(
            &path,
            CONTENT_HASH,
            &FileReadingState {
                page: 0,
                location_offset: None,
                zoom: 0.25,
            },
        )
        .await
        .unwrap();

    let state = store.get_async(&path, CONTENT_HASH).await.unwrap().unwrap();
    assert!((state.zoom - 0.25).abs() < f32::EPSILON);
}

#[tokio::test]
async fn test_path_with_spaces_and_unicode() {
    let (store, _dir) = temp_store().await;
    let path = PathBuf::from("/my books/日本語の本 (copy).pdf");

    store
        .set_async(
            &path,
            CONTENT_HASH,
            &FileReadingState {
                page: 3,
                location_offset: None,
                zoom: 1.5,
            },
        )
        .await
        .unwrap();

    let state = store.get_async(&path, CONTENT_HASH).await.unwrap().unwrap();
    assert_eq!(state.page, 3);
}

#[tokio::test]
async fn test_open_creates_parent_directories() {
    let dir = TempDir::new().unwrap();
    let db_path = dir.path().join("nested").join("dirs").join("shosai.db");

    // Should create nested/dirs/ automatically
    let store = ReadingStateStore::open_at_async(&db_path).await.unwrap();
    store
        .set_async(
            &PathBuf::from("/test.pdf"),
            CONTENT_HASH,
            &FileReadingState {
                page: 1,
                location_offset: None,
                zoom: 1.0,
            },
        )
        .await
        .unwrap();

    assert!(db_path.exists());
}
