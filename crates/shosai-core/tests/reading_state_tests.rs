use shosai_core::reading_state::{FileReadingState, ReadingStateStore};
use sqlx::sqlite::{SqliteConnectOptions, SqlitePool};
use std::borrow::Cow;
use std::path::PathBuf;
use tempfile::TempDir;

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

/// Each test gets its own temporary directory (and therefore its own database).
/// The directory is cleaned up automatically when `TempDir` is dropped.
async fn temp_store() -> (ReadingStateStore, TempDir) {
    let dir = TempDir::new().unwrap();
    let db_path = dir.path().join("shosai.db");
    let store = ReadingStateStore::open_at_async(&db_path).await.unwrap();
    (store, dir)
}

// ---------------------------------------------------------------------------
// Basic CRUD
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_get_nonexistent_returns_none() {
    let (store, _dir) = temp_store().await;
    assert!(
        store
            .get_async(&PathBuf::from("/no/such/file.pdf"))
            .await
            .is_none()
    );
}

#[tokio::test]
async fn test_set_then_get() {
    let (store, _dir) = temp_store().await;
    let path = PathBuf::from("/books/rust.pdf");

    store
        .set_async(
            &path,
            &FileReadingState {
                page: 5,
                location_offset: None,
                zoom: 1.5,
            },
        )
        .await
        .unwrap();

    let state = store
        .get_async(&path)
        .await
        .expect("should exist after set");
    assert_eq!(state.page, 5);
    assert!((state.zoom - 1.5).abs() < f32::EPSILON);
}

#[tokio::test]
async fn test_epub_character_offset_persists() {
    let (store, _dir) = temp_store().await;
    let path = PathBuf::from("/books/example.epub");

    store
        .set_async(
            &path,
            &FileReadingState {
                page: 4,
                location_offset: Some(1_234),
                zoom: 1.0,
            },
        )
        .await
        .unwrap();

    let state = store.get_async(&path).await.unwrap();
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
            &FileReadingState {
                page: 42,
                location_offset: None,
                zoom: 3.0,
            },
        )
        .await
        .unwrap();

    let state = store.get_async(&path).await.unwrap();
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
            &FileReadingState {
                page: 99,
                location_offset: None,
                zoom: 2.5,
            },
        )
        .await
        .unwrap();

    let sa = store.get_async(&a).await.unwrap();
    assert_eq!(sa.page, 1);
    assert!((sa.zoom - 1.0).abs() < f32::EPSILON);

    let sb = store.get_async(&b).await.unwrap();
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
            &FileReadingState {
                page: 50,
                location_offset: None,
                zoom: 4.0,
            },
        )
        .await
        .unwrap();

    // a should be untouched
    let sa = store.get_async(&a).await.unwrap();
    assert_eq!(sa.page, 10);

    let sb = store.get_async(&b).await.unwrap();
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
        let state = store.get_async(&path).await.expect("should persist");
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
        .get_async(&path)
        .await
        .expect("data should survive re-migration");
    assert_eq!(state.page, 7);
    assert!((state.zoom - 1.25).abs() < f32::EPSILON);
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
async fn stable_save_replaces_a_path_only_alias() {
    let (store, _dir) = temp_store().await;
    let path = PathBuf::from("/books/relinked.epub");
    let book_id: i64 = sqlx::query_scalar(
        "INSERT INTO books (title, format, file_path) VALUES ('Book', 'epub', '/old.epub')
         RETURNING id",
    )
    .fetch_one(store.pool())
    .await
    .unwrap();
    store
        .set_async(
            &path,
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
            &path,
            &FileReadingState {
                page: 9,
                location_offset: Some(3),
                zoom: 1.5,
            },
        )
        .await
        .unwrap();

    let state = store.get_for_book_async(book_id).await.unwrap();
    assert_eq!(state.page, 9);
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM reading_state WHERE file_path = ?")
        .bind(path.to_string_lossy().as_ref())
        .fetch_one(store.pool())
        .await
        .unwrap();
    assert_eq!(count, 1);
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
            &FileReadingState {
                page: 0,
                location_offset: None,
                zoom: 1.0,
            },
        )
        .await
        .unwrap();

    let state = store.get_async(&path).await.unwrap();
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
            &FileReadingState {
                page: 999_999,
                location_offset: None,
                zoom: 5.0,
            },
        )
        .await
        .unwrap();

    let state = store.get_async(&path).await.unwrap();
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
            &FileReadingState {
                page: 0,
                location_offset: None,
                zoom: 0.25,
            },
        )
        .await
        .unwrap();

    let state = store.get_async(&path).await.unwrap();
    assert!((state.zoom - 0.25).abs() < f32::EPSILON);
}

#[tokio::test]
async fn test_path_with_spaces_and_unicode() {
    let (store, _dir) = temp_store().await;
    let path = PathBuf::from("/my books/日本語の本 (copy).pdf");

    store
        .set_async(
            &path,
            &FileReadingState {
                page: 3,
                location_offset: None,
                zoom: 1.5,
            },
        )
        .await
        .unwrap();

    let state = store.get_async(&path).await.unwrap();
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
