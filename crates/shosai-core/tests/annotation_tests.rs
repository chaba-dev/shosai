use std::borrow::Cow;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::Duration;

use shosai_core::annotations::{
    AnnotationAssociationConflict, AnnotationAssociationOutcome,
    AnnotationAssociationSourceCancelled, AnnotationDocumentFormat, AnnotationId,
    AnnotationSnapshotLimit, AnnotationStore, AnnotationTarget, DocumentFingerprint, EpubAnchor,
    HighlightColor, ImportProvenance, MAX_ANNOTATION_BODY_SCALARS, MAX_EPUB_RESOURCE_PATH_BYTES,
    MAX_FINGERPRINT_ALGORITHM_BYTES, MAX_FINGERPRINT_BYTES, MAX_LOCAL_PATH_BYTES,
    MAX_PDF_RECTANGLES, MAX_PROVENANCE_ID_BYTES, MAX_PROVENANCE_SYSTEM_BYTES,
    MAX_QUOTE_CONTEXT_INPUT_SCALARS, MAX_QUOTE_SCALARS, NewAnnotation, PageRect, PdfAnchor,
    QuoteSelector, normalize_quote_v1, scalar_range_to_utf16,
};
use shosai_core::reading_state::ReadingStateStore;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePool, SqlitePoolOptions};
use tempfile::TempDir;

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

async fn temp_store() -> (AnnotationStore, sqlx::SqlitePool, TempDir) {
    let dir = TempDir::new().unwrap();
    let state = ReadingStateStore::open_at_async(&dir.path().join("shosai.db"))
        .await
        .unwrap();
    let pool = state.pool().clone();
    (AnnotationStore::new(pool.clone()), pool, dir)
}

async fn single_connection_store() -> (AnnotationStore, SqlitePool, TempDir) {
    let dir = TempDir::new().unwrap();
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(
            SqliteConnectOptions::new()
                .filename(dir.path().join("shosai.db"))
                .create_if_missing(true),
        )
        .await
        .unwrap();
    MIGRATOR.run(&pool).await.unwrap();
    (AnnotationStore::new(pool.clone()), pool, dir)
}

fn fingerprint() -> DocumentFingerprint {
    DocumentFingerprint::new("sha256", 1, vec![0xab; 32]).unwrap()
}

fn epub_annotation(book_id: Option<i64>) -> NewAnnotation {
    NewAnnotation {
        id: AnnotationId::new(),
        book_id,
        local_path: Some("/books/example.epub".into()),
        fingerprint: fingerprint(),
        quote: Some(QuoteSelector::new("Cafe\u{301}", "before ", " after").unwrap()),
        target: AnnotationTarget::Epub(EpubAnchor::new(2, "EPUB/chapter.xhtml", 10, 15).unwrap()),
        color: HighlightColor::Yellow,
        body: None,
        provenance: None,
    }
}

#[test]
fn quote_v1_golden_vectors_pin_normalization_and_context_direction() {
    assert_eq!(normalize_quote_v1("Cafe\u{301}"), "Café");
    assert_eq!(normalize_quote_v1(" a\r\n\t b\u{a0}c "), "a b c");
    assert_eq!(normalize_quote_v1("co\u{ad}operate"), "cooperate");
    assert_eq!(normalize_quote_v1("Case—A-B! ﬁ"), "Case—A-B! ﬁ");
    assert_ne!(normalize_quote_v1("Résumé"), normalize_quote_v1("résumé"));

    let selector = QuoteSelector::new(
        "selected",
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ",
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    )
    .unwrap();
    assert_eq!(selector.prefix, "456789ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    assert_eq!(selector.suffix, "0123456789ABCDEFGHIJKLMNOPQRSTUV");

    let selector = QuoteSelector::new("selected", &format!("{}é", "x".repeat(31)), "").unwrap();
    assert_eq!(selector.prefix, format!("{}é", "x".repeat(31)));

    let selector = QuoteSelector::new(
        "selected",
        &format!("👩‍🔬{}", "x".repeat(31)),
        &format!("{}👩‍🔬", "x".repeat(31)),
    )
    .unwrap();
    assert_eq!(selector.prefix, "x".repeat(31));
    assert_eq!(selector.suffix, "x".repeat(31));

    let selector = QuoteSelector::new(
        "selected",
        &format!("{} {}", "discarded", "p".repeat(31)),
        &format!("{} {}", "s".repeat(31), "discarded"),
    )
    .unwrap();
    assert_eq!(selector.prefix, "p".repeat(31));
    assert_eq!(selector.suffix, "s".repeat(31));
}

#[test]
fn scalar_offsets_convert_explicitly_to_utf16_units() {
    assert_eq!(scalar_range_to_utf16("A😀é", 1..3).unwrap(), 1..4);
    assert!(scalar_range_to_utf16("short", std::ops::Range { start: 4, end: 3 }).is_err());
    assert!(scalar_range_to_utf16("short", 0..6).is_err());
}

#[test]
fn annotation_inputs_enforce_exact_resource_limits_before_persistence() {
    assert!(QuoteSelector::new(&"x".repeat(MAX_QUOTE_SCALARS), "", "").is_ok());
    assert!(QuoteSelector::new(&"x".repeat(MAX_QUOTE_SCALARS + 1), "", "").is_err());
    assert!(
        QuoteSelector::new(
            "selected",
            &"x".repeat(MAX_QUOTE_CONTEXT_INPUT_SCALARS + 1),
            ""
        )
        .is_err()
    );
    assert!(DocumentFingerprint::new("sha256", 1, vec![0; MAX_FINGERPRINT_BYTES]).is_ok());
    assert!(DocumentFingerprint::new("sha256", 1, vec![0; MAX_FINGERPRINT_BYTES + 1]).is_err());
    assert!(
        DocumentFingerprint::new("x".repeat(MAX_FINGERPRINT_ALGORITHM_BYTES + 1), 1, vec![0])
            .is_err()
    );
    assert!(
        EpubAnchor::new(
            0,
            format!("{}.xhtml", "x".repeat(MAX_EPUB_RESOURCE_PATH_BYTES)),
            0,
            1
        )
        .is_err()
    );
}

#[tokio::test]
async fn exact_persisted_value_limits_round_trip() {
    let (store, pool, _dir) = temp_store().await;
    let resource_path = format!(
        "{}.xhtml",
        "x".repeat(MAX_EPUB_RESOURCE_PATH_BYTES - ".xhtml".len())
    );
    let input = NewAnnotation {
        id: AnnotationId::new(),
        book_id: None,
        local_path: Some("x".repeat(MAX_LOCAL_PATH_BYTES)),
        fingerprint: DocumentFingerprint::new(
            "x".repeat(MAX_FINGERPRINT_ALGORITHM_BYTES),
            1,
            vec![0; MAX_FINGERPRINT_BYTES],
        )
        .unwrap(),
        quote: Some(
            QuoteSelector::new(
                &"x".repeat(MAX_QUOTE_SCALARS),
                &"x".repeat(MAX_QUOTE_CONTEXT_INPUT_SCALARS),
                &"x".repeat(MAX_QUOTE_CONTEXT_INPUT_SCALARS),
            )
            .unwrap(),
        ),
        target: AnnotationTarget::Epub(EpubAnchor::new(0, resource_path, 0, 1).unwrap()),
        color: HighlightColor::Green,
        body: Some("x".repeat(MAX_ANNOTATION_BODY_SCALARS)),
        provenance: Some(ImportProvenance {
            source_system: "x".repeat(MAX_PROVENANCE_SYSTEM_BYTES),
            source_id: Some("x".repeat(MAX_PROVENANCE_ID_BYTES)),
        }),
    };

    let loaded = store.create_async(&input).await.unwrap();
    assert_eq!(loaded.body, input.body);
    assert_eq!(loaded.local_path, input.local_path);
    assert_eq!(loaded.provenance, input.provenance);

    let oversized_utf8_path = "é".repeat(MAX_LOCAL_PATH_BYTES / 2 + 1);
    assert!(
        sqlx::query("UPDATE annotations SET local_path = ? WHERE id = ?")
            .bind(oversized_utf8_path)
            .bind(input.id.to_string())
            .execute(&pool)
            .await
            .is_err(),
        "SQLite byte limits must match the Rust persistence contract"
    );
}

#[test]
fn epub_annotations_reuse_the_authoritative_canonical_path_contract() {
    for invalid in [
        "",
        "/OEBPS/chapter.xhtml",
        "OEBPS//chapter.xhtml",
        "OEBPS/./chapter.xhtml",
        "OEBPS/../chapter.xhtml",
        "OEBPS\\chapter.xhtml",
        "OEBPS/chapter.xhtml/",
        "OEBPS/\u{7f}chapter.xhtml",
    ] {
        assert!(
            EpubAnchor::new(0, invalid, 0, 1).is_err(),
            "accepted noncanonical EPUB path {invalid:?}"
        );
    }
}

#[tokio::test]
async fn epub_annotation_round_trips_and_updates() {
    let (store, pool, _dir) = temp_store().await;
    let book_id: i64 = sqlx::query_scalar(
        "INSERT INTO books (title, format, file_path) VALUES ('Example', 'epub', '/books/example.epub') RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    let input = epub_annotation(Some(book_id));
    let created = store.create_async(&input).await.unwrap();

    assert_eq!(created.id, input.id);
    assert_eq!(created.book_id, Some(book_id));
    assert_eq!(created.quote.as_ref().unwrap().exact, "Café");
    assert_eq!(created.target, input.target);
    assert!(created.deleted_at.is_none());

    assert!(
        store
            .update_async(&created.id, HighlightColor::Purple, Some("Remember this"))
            .await
            .unwrap()
    );
    let updated = store.get_async(&created.id, false).await.unwrap().unwrap();
    assert_eq!(updated.color, HighlightColor::Purple);
    assert_eq!(updated.body.as_deref(), Some("Remember this"));
    assert_ne!(updated.modified_at, created.modified_at);
    assert_eq!(updated.created_at, created.created_at);
    assert_eq!(store.list_for_book_async(book_id).await.unwrap().len(), 1);
}

#[tokio::test]
async fn untracked_annotations_reopen_by_device_local_path() {
    let (store, _pool, _dir) = temp_store().await;
    let mut first = epub_annotation(None);
    first.local_path = Some("device://book.epub".to_owned());
    store.create_async(&first).await.unwrap();
    let mut other = epub_annotation(None);
    other.local_path = Some("device://other.epub".to_owned());
    store.create_async(&other).await.unwrap();

    let reopened = store
        .list_for_local_path_async("device://book.epub")
        .await
        .unwrap();
    assert_eq!(reopened.len(), 1);
    assert_eq!(reopened[0].id, first.id);
}

#[tokio::test]
async fn untracked_annotations_share_only_their_exact_document_version() {
    let (store, pool, _dir) = temp_store().await;
    let first = epub_annotation(None);
    let second = epub_annotation(None);
    let mut changed = epub_annotation(None);
    changed.fingerprint = DocumentFingerprint::new("sha256", 1, vec![0xcd; 32]).unwrap();

    store.create_async(&first).await.unwrap();
    store.create_async(&second).await.unwrap();
    store.create_async(&changed).await.unwrap();

    let first_document: String =
        sqlx::query_scalar("SELECT annotation_document_id FROM annotations WHERE id = ?")
            .bind(first.id.to_string())
            .fetch_one(&pool)
            .await
            .unwrap();
    let second_document: String =
        sqlx::query_scalar("SELECT annotation_document_id FROM annotations WHERE id = ?")
            .bind(second.id.to_string())
            .fetch_one(&pool)
            .await
            .unwrap();
    let changed_document: String =
        sqlx::query_scalar("SELECT annotation_document_id FROM annotations WHERE id = ?")
            .bind(changed.id.to_string())
            .fetch_one(&pool)
            .await
            .unwrap();

    assert_eq!(first_document, second_document);
    assert_ne!(first_document, changed_document);
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM annotation_documents")
            .fetch_one(&pool)
            .await
            .unwrap(),
        2
    );
    assert_eq!(
        store
            .list_for_local_path_async("/books/example.epub")
            .await
            .unwrap()
            .len(),
        3,
        "path-only discovery remains able to show explicit association sources"
    );
}

#[tokio::test]
async fn identical_path_and_fingerprint_remain_distinct_across_formats() {
    let (store, pool, _dir) = temp_store().await;
    let epub = epub_annotation(None);
    let mut pdf = epub_annotation(None);
    pdf.target = AnnotationTarget::Pdf(
        PdfAnchor::new(
            0,
            Some((0, 8)),
            vec![PageRect::new(0.0, 0.0, 1.0, 1.0).unwrap()],
        )
        .unwrap(),
    );

    store.create_async(&epub).await.unwrap();
    store.create_async(&pdf).await.unwrap();

    let formats: Vec<(String, String)> = sqlx::query_as(
        "SELECT d.format, a.annotation_document_id
         FROM annotations a
         JOIN annotation_documents d ON d.id = a.annotation_document_id
         WHERE a.id IN (?, ?) ORDER BY d.format",
    )
    .bind(epub.id.to_string())
    .bind(pdf.id.to_string())
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(formats.len(), 2);
    assert_eq!(formats[0].0, "epub");
    assert_eq!(formats[1].0, "pdf");
    assert_ne!(formats[0].1, formats[1].1);
}

#[tokio::test]
async fn concurrent_first_annotations_create_one_exact_document_version() {
    let (store, pool, _dir) = temp_store().await;
    let first = epub_annotation(None);
    let second = epub_annotation(None);
    let (first_result, second_result) =
        tokio::join!(store.create_async(&first), store.create_async(&second),);
    first_result.unwrap();
    second_result.unwrap();

    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM annotation_documents")
            .fetch_one(&pool)
            .await
            .unwrap(),
        1
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM annotation_document_versions")
            .fetch_one(&pool)
            .await
            .unwrap(),
        1
    );
    assert_eq!(
        store
            .list_for_local_path_async("/books/example.epub")
            .await
            .unwrap()
            .len(),
        2
    );
}

#[tokio::test]
async fn explicit_document_association_preserves_anchor_evidence_and_rejects_conflicts() {
    let (store, pool, _dir) = temp_store().await;
    let source = epub_annotation(None);
    store.create_async(&source).await.unwrap();
    let changed_fingerprint = DocumentFingerprint::new("sha256", 1, vec![0xcd; 32]).unwrap();
    let source_page = store
        .list_association_sources_async(
            AnnotationDocumentFormat::Epub,
            "/replacements/changed.epub",
            &changed_fingerprint,
            None,
            10,
        )
        .await
        .unwrap();
    assert_eq!(source_page.sources.len(), 1);
    assert_eq!(source_page.sources[0].live_annotations, 1);
    assert!(source_page.next_cursor.is_none());
    let source_version = &source_page.sources[0].version_id;

    assert_eq!(
        store
            .associate_document_version_async(
                source_version,
                AnnotationDocumentFormat::Epub,
                "/replacements/changed.epub",
                &changed_fingerprint,
            )
            .await
            .unwrap(),
        AnnotationAssociationOutcome::Associated
    );
    assert_eq!(
        store
            .associate_document_version_async(
                source_version,
                AnnotationDocumentFormat::Epub,
                "/replacements/changed.epub",
                &changed_fingerprint,
            )
            .await
            .unwrap(),
        AnnotationAssociationOutcome::AlreadyAssociated
    );
    assert!(
        store
            .list_association_sources_async(
                AnnotationDocumentFormat::Epub,
                "/replacements/changed.epub",
                &changed_fingerprint,
                None,
                10,
            )
            .await
            .unwrap()
            .sources
            .is_empty(),
        "the target's existing collection is not an earlier-version choice"
    );
    let stored_source = store.get_async(&source.id, false).await.unwrap().unwrap();
    assert_eq!(stored_source.local_path, source.local_path);
    assert_eq!(stored_source.fingerprint, source.fingerprint);
    let associated_from: String = sqlx::query_scalar(
        "SELECT associated_from_version_id FROM annotation_document_versions
         WHERE local_path = '/replacements/changed.epub'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(associated_from, source_version.to_string());

    let mut target_annotation = epub_annotation(None);
    target_annotation.local_path = Some("/replacements/changed.epub".into());
    target_annotation.fingerprint = changed_fingerprint.clone();
    store.create_async(&target_annotation).await.unwrap();
    let distinct_documents: i64 = sqlx::query_scalar(
        "SELECT COUNT(DISTINCT annotation_document_id) FROM annotations
         WHERE id IN (?, ?)",
    )
    .bind(source.id.to_string())
    .bind(target_annotation.id.to_string())
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(distinct_documents, 1);

    let mut unrelated = epub_annotation(None);
    unrelated.local_path = Some("/replacements/unrelated.epub".into());
    unrelated.fingerprint = DocumentFingerprint::new("sha256", 1, vec![0xef; 32]).unwrap();
    store.create_async(&unrelated).await.unwrap();
    let conflict = store
        .associate_document_version_async(
            source_version,
            AnnotationDocumentFormat::Epub,
            unrelated.local_path.as_deref().unwrap(),
            &unrelated.fingerprint,
        )
        .await
        .unwrap_err();
    assert!(conflict.is::<AnnotationAssociationConflict>());
}

#[tokio::test]
async fn tombstone_only_collections_are_not_association_choices() {
    let (store, _pool, _dir) = temp_store().await;
    let source = store.create_async(&epub_annotation(None)).await.unwrap();
    store.delete_async(&source.id).await.unwrap();

    let page = store
        .list_association_sources_async(
            AnnotationDocumentFormat::Epub,
            "/target.epub",
            &DocumentFingerprint::new("sha256", 1, vec![0xcd; 32]).unwrap(),
            None,
            1,
        )
        .await
        .unwrap();
    assert!(page.sources.is_empty());
}

#[tokio::test]
async fn association_source_pages_filter_format_and_tombstones_before_limit() {
    let (store, pool, _dir) = temp_store().await;
    for index in 0..100 {
        let mut annotation = epub_annotation(None);
        annotation.local_path = Some(format!("/books/deleted-{index}.epub"));
        annotation.fingerprint =
            DocumentFingerprint::new("sha256", 1, vec![u8::try_from(index).unwrap(); 32]).unwrap();
        let deleted = store.create_async(&annotation).await.unwrap();
        store.delete_async(&deleted.id).await.unwrap();
    }
    let cancellation_checks = Arc::new(AtomicUsize::new(0));
    let error = store
        .list_association_sources_cancellable_async(
            AnnotationDocumentFormat::Epub,
            "/target.epub",
            &DocumentFingerprint::new("sha256", 1, vec![0xcd; 32]).unwrap(),
            None,
            1,
            (
                {
                    let cancellation_checks = Arc::clone(&cancellation_checks);
                    move || cancellation_checks.fetch_add(1, Ordering::Relaxed) > 1
                },
                std::future::pending(),
            ),
        )
        .await
        .unwrap_err();
    assert!(error.is::<AnnotationAssociationSourceCancelled>());
    assert!(
        cancellation_checks.load(Ordering::Relaxed) > 2,
        "cancellation must be observed by SQLite's progress handler"
    );

    let live = store.create_async(&epub_annotation(None)).await.unwrap();
    let mut pdf = epub_annotation(None);
    pdf.target = AnnotationTarget::Pdf(
        PdfAnchor::new(
            0,
            Some((0, 8)),
            vec![PageRect::new(0.0, 0.0, 1.0, 1.0).unwrap()],
        )
        .unwrap(),
    );
    store.create_async(&pdf).await.unwrap();

    let page = store
        .list_association_sources_async(
            AnnotationDocumentFormat::Epub,
            "/target.epub",
            &DocumentFingerprint::new("sha256", 1, vec![0xcd; 32]).unwrap(),
            None,
            1,
        )
        .await
        .unwrap();
    assert_eq!(page.sources.len(), 1);
    assert_eq!(page.sources[0].format, AnnotationDocumentFormat::Epub);
    assert_eq!(page.sources[0].live_annotations, 1);

    let document_id: String =
        sqlx::query_scalar("SELECT annotation_document_id FROM annotations WHERE id = ?")
            .bind(live.id.to_string())
            .fetch_one(&pool)
            .await
            .unwrap();
    let plan: Vec<(i64, i64, i64, String)> = sqlx::query_as(
        "EXPLAIN QUERY PLAN
         SELECT 1 FROM annotations
         WHERE annotation_document_id = ? AND deleted_at IS NULL LIMIT 1",
    )
    .bind(document_id)
    .fetch_all(&pool)
    .await
    .unwrap();
    assert!(
        plan.iter()
            .any(|(_, _, _, detail)| detail.contains("annotations_document_active_idx")),
        "live-source lookup must use the collection/deletion index: {plan:?}"
    );
    let page_plan: Vec<(i64, i64, i64, String)> = sqlx::query_as(
        "EXPLAIN QUERY PLAN
         SELECT v.id FROM annotation_document_versions v
         WHERE v.format = ? AND v.id > ?
           AND EXISTS (
             SELECT 1 FROM annotations a
             WHERE a.annotation_document_id = v.document_id
               AND a.deleted_at IS NULL
           )
         ORDER BY v.id LIMIT ?",
    )
    .bind("epub")
    .bind("")
    .bind(2_i64)
    .fetch_all(&pool)
    .await
    .unwrap();
    assert!(
        page_plan.iter().any(|(_, _, _, detail)| {
            detail.contains("annotation_document_versions_format_id_idx")
                && detail.contains("format=? AND id>?")
        }),
        "source-page lookup must seek by format and cursor: {page_plan:?}"
    );
    assert!(
        page_plan
            .iter()
            .any(|(_, _, _, detail)| detail.contains("annotations_document_active_idx")),
        "source-page filtering must use the live annotation index: {page_plan:?}"
    );
}

#[tokio::test]
async fn aborted_source_discovery_cannot_contaminate_a_pooled_connection() {
    let (store, pool, _dir) = single_connection_store().await;
    for index in 0..100 {
        let mut annotation = epub_annotation(None);
        annotation.local_path = Some(format!("/books/aborted-{index}.epub"));
        annotation.fingerprint =
            DocumentFingerprint::new("sha256", 1, vec![u8::try_from(index).unwrap(); 32]).unwrap();
        let deleted = store.create_async(&annotation).await.unwrap();
        store.delete_async(&deleted.id).await.unwrap();
    }

    let checks = Arc::new(AtomicUsize::new(0));
    let handler_started = Arc::new(AtomicBool::new(false));
    let release_handler = Arc::new(AtomicBool::new(false));
    let cancel_query = Arc::new(AtomicBool::new(false));
    let task = {
        let store = store.clone();
        let checks = Arc::clone(&checks);
        let handler_started = Arc::clone(&handler_started);
        let release_handler = Arc::clone(&release_handler);
        let cancel_query = Arc::clone(&cancel_query);
        tokio::spawn(async move {
            store
                .list_association_sources_cancellable_async(
                    AnnotationDocumentFormat::Epub,
                    "/target.epub",
                    &DocumentFingerprint::new("sha256", 1, vec![0xcd; 32]).unwrap(),
                    None,
                    1,
                    (
                        move || {
                            let check = checks.fetch_add(1, Ordering::Relaxed);
                            if check >= 2 {
                                handler_started.store(true, Ordering::Release);
                                while !release_handler.load(Ordering::Acquire) {
                                    std::thread::yield_now();
                                }
                            }
                            cancel_query.load(Ordering::Acquire)
                        },
                        std::future::pending(),
                    ),
                )
                .await
        })
    };
    tokio::time::timeout(Duration::from_secs(2), async {
        while !handler_started.load(Ordering::Acquire) {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("source discovery must enter its SQLite progress handler");
    task.abort();
    cancel_query.store(true, Ordering::Release);
    release_handler.store(true, Ordering::Release);
    assert!(task.await.unwrap_err().is_cancelled());

    let sum = tokio::time::timeout(
        Duration::from_secs(2),
        sqlx::query_scalar::<_, i64>(
            "WITH RECURSIVE numbers(value) AS (
               VALUES(1) UNION ALL SELECT value + 1 FROM numbers WHERE value < 10000
             ) SELECT SUM(value) FROM numbers",
        )
        .fetch_one(&pool),
    )
    .await
    .expect("the replacement connection must be available")
    .expect("an abandoned progress handler must not interrupt later SQL");
    assert_eq!(sum, 50_005_000);
}

#[tokio::test]
async fn source_discovery_cancels_while_waiting_for_a_connection() {
    let (store, pool, _dir) = single_connection_store().await;
    let _held_connection = pool.acquire().await.unwrap();

    let error = tokio::time::timeout(
        Duration::from_secs(1),
        store.list_association_sources_cancellable_async(
            AnnotationDocumentFormat::Epub,
            "/target.epub",
            &DocumentFingerprint::new("sha256", 1, vec![0xcd; 32]).unwrap(),
            None,
            1,
            (|| false, async { tokio::task::yield_now().await }),
        ),
    )
    .await
    .expect("cancellation must not wait for the held connection")
    .unwrap_err();
    assert!(error.is::<AnnotationAssociationSourceCancelled>());
}

#[tokio::test]
async fn source_discovery_cancels_while_sqlite_waits_on_a_lock() {
    let dir = TempDir::new().unwrap();
    let pool = SqlitePoolOptions::new()
        .max_connections(2)
        .connect_with(
            SqliteConnectOptions::new()
                .filename(dir.path().join("shosai.db"))
                .create_if_missing(true)
                .busy_timeout(Duration::from_secs(5)),
        )
        .await
        .unwrap();
    MIGRATOR.run(&pool).await.unwrap();
    let store = AnnotationStore::new(pool.clone());
    let mut locking_connection = pool.acquire().await.unwrap();
    let spare_connection = pool.acquire().await.unwrap();
    drop(spare_connection);
    sqlx::query("BEGIN EXCLUSIVE")
        .execute(&mut *locking_connection)
        .await
        .unwrap();

    let cancelled = Arc::new(AtomicBool::new(false));
    let cancellation = Arc::new(tokio::sync::Notify::new());
    let task = {
        let cancelled = Arc::clone(&cancelled);
        let cancellation = Arc::clone(&cancellation);
        tokio::spawn(async move {
            store
                .list_association_sources_cancellable_async(
                    AnnotationDocumentFormat::Epub,
                    "/target.epub",
                    &DocumentFingerprint::new("sha256", 1, vec![0xcd; 32]).unwrap(),
                    None,
                    1,
                    (move || cancelled.load(Ordering::Acquire), async move {
                        cancellation.notified().await
                    }),
                )
                .await
        })
    };
    tokio::time::sleep(Duration::from_millis(50)).await;
    cancelled.store(true, Ordering::Release);
    cancellation.notify_one();

    let error = tokio::time::timeout(Duration::from_secs(1), task)
        .await
        .expect("cancellation must interrupt SQLite's lock wait")
        .unwrap()
        .unwrap_err();
    assert!(error.is::<AnnotationAssociationSourceCancelled>());
    sqlx::query("ROLLBACK")
        .execute(&mut *locking_connection)
        .await
        .unwrap();
}

#[tokio::test]
async fn association_source_pages_navigate_without_retaining_prior_pages() {
    let (store, _pool, _dir) = temp_store().await;
    for index in 0..65 {
        let mut annotation = epub_annotation(None);
        annotation.local_path = Some(format!("/books/source-{index}.epub"));
        annotation.fingerprint =
            DocumentFingerprint::new("sha256", 1, vec![u8::try_from(index).unwrap(); 32]).unwrap();
        store.create_async(&annotation).await.unwrap();
    }
    let target_fingerprint = DocumentFingerprint::new("sha256", 1, vec![0xff; 32]).unwrap();
    let first = store
        .list_association_sources_async(
            AnnotationDocumentFormat::Epub,
            "/target.epub",
            &target_fingerprint,
            None,
            32,
        )
        .await
        .unwrap();
    let second = store
        .list_association_sources_async(
            AnnotationDocumentFormat::Epub,
            "/target.epub",
            &target_fingerprint,
            first.next_cursor.as_ref(),
            32,
        )
        .await
        .unwrap();
    let third = store
        .list_association_sources_async(
            AnnotationDocumentFormat::Epub,
            "/target.epub",
            &target_fingerprint,
            second.next_cursor.as_ref(),
            32,
        )
        .await
        .unwrap();
    assert_eq!(first.sources.len(), 32);
    assert_eq!(second.sources.len(), 32);
    assert_eq!(third.sources.len(), 1);
    assert!(second.previous_cursor.is_none());
    assert_eq!(third.previous_cursor, first.next_cursor);

    let previous = store
        .list_association_sources_async(
            AnnotationDocumentFormat::Epub,
            "/target.epub",
            &target_fingerprint,
            third.previous_cursor.as_ref(),
            32,
        )
        .await
        .unwrap();
    assert_eq!(previous.sources, second.sources);
}

#[tokio::test]
async fn annotation_document_migration_backfills_exact_versions_including_tombstones() {
    let dir = TempDir::new().unwrap();
    let db_path = dir.path().join("shosai.db");
    let pool = SqlitePool::connect_with(
        SqliteConnectOptions::new()
            .filename(&db_path)
            .create_if_missing(true),
    )
    .await
    .unwrap();
    let v13_migrator = sqlx::migrate::Migrator {
        migrations: Cow::Owned(MIGRATOR.migrations[..13].to_vec()),
        ..sqlx::migrate::Migrator::DEFAULT
    };
    v13_migrator.run(&pool).await.unwrap();
    let ids = [
        AnnotationId::new().to_string(),
        AnnotationId::new().to_string(),
        AnnotationId::new().to_string(),
    ];
    for (index, id) in ids.iter().enumerate() {
        sqlx::query(
            "INSERT INTO annotations (
                id, local_path, format, anchor_version,
                fingerprint_algorithm, fingerprint_version, fingerprint,
                original_quote, normalization_profile, normalized_exact,
                normalized_prefix, normalized_suffix, color,
                epub_spine_occurrence, epub_resource_path,
                epub_scalar_start, epub_scalar_end, deleted_at)
             VALUES (?, '/books/example.epub', 'epub', 1,
                     'sha256', 1, ?, 'selected', 'shosai-quote-v1',
                     'selected', '', '', 'yellow', 0, 'chapter.xhtml', 0, 8, ?)",
        )
        .bind(id)
        .bind(if index == 2 {
            vec![0xcd; 32]
        } else {
            vec![0xab; 32]
        })
        .bind((index == 1).then_some("2026-01-01T00:00:00Z"))
        .execute(&pool)
        .await
        .unwrap();
    }
    let pdf_id = AnnotationId::new().to_string();
    sqlx::query(
        "INSERT INTO annotations (
            id, local_path, format, anchor_version,
            fingerprint_algorithm, fingerprint_version, fingerprint,
            original_quote, normalization_profile, normalized_exact,
            normalized_prefix, normalized_suffix, color,
            pdf_page, pdf_char_start, pdf_char_end)
         VALUES (?, '/books/example.epub', 'pdf', 1,
                 'sha256', 1, ?, 'selected', 'shosai-quote-v1',
                 'selected', '', '', 'yellow', 0, 0, 8)",
    )
    .bind(&pdf_id)
    .bind(vec![0xab; 32])
    .execute(&pool)
    .await
    .unwrap();

    MIGRATOR.run(&pool).await.unwrap();

    let documents: Vec<(String, String)> =
        sqlx::query_as("SELECT id, annotation_document_id FROM annotations ORDER BY id")
            .fetch_all(&pool)
            .await
            .unwrap();
    let first_document = documents
        .iter()
        .find(|(id, _)| id == &ids[0])
        .unwrap()
        .1
        .clone();
    assert_eq!(
        documents.iter().find(|(id, _)| id == &ids[1]).unwrap().1,
        first_document,
        "deleted records remain in the same durable collection"
    );
    assert_ne!(
        documents.iter().find(|(id, _)| id == &ids[2]).unwrap().1,
        first_document,
        "path equality must not associate changed bytes"
    );
    let pdf_document: String =
        sqlx::query_scalar("SELECT annotation_document_id FROM annotations WHERE id = ?")
            .bind(pdf_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_ne!(
        pdf_document, first_document,
        "format is part of exact document-version identity"
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM annotation_document_versions")
            .fetch_one(&pool)
            .await
            .unwrap(),
        3
    );
}

#[tokio::test]
async fn aggregate_limit_rejects_create_and_update_before_commit() {
    let (store, _pool, _dir) = temp_store().await;
    let mut editable = epub_annotation(None);
    editable.body = None;
    let editable = store.create_async(&editable).await.unwrap();
    let mut accepted = 1;

    loop {
        let mut candidate = epub_annotation(None);
        candidate.body = Some("x".repeat(MAX_ANNOTATION_BODY_SCALARS));
        match store.create_async(&candidate).await {
            Ok(_) => accepted += 1,
            Err(error) => {
                assert!(error.is::<AnnotationSnapshotLimit>());
                break;
            }
        }
    }
    assert_eq!(
        store
            .list_for_local_path_async("/books/example.epub")
            .await
            .unwrap()
            .len(),
        accepted,
        "the rejected create must roll back"
    );

    let error = store
        .update_async(
            &editable.id,
            HighlightColor::Purple,
            Some(&"😀".repeat(MAX_ANNOTATION_BODY_SCALARS)),
        )
        .await
        .unwrap_err();
    assert!(error.is::<AnnotationSnapshotLimit>());
    let unchanged = store.get_async(&editable.id, false).await.unwrap().unwrap();
    assert_eq!(unchanged.color, HighlightColor::Yellow);
    assert_eq!(unchanged.body, None, "the rejected update must roll back");
    assert_eq!(
        store
            .list_for_local_path_async("/books/example.epub")
            .await
            .unwrap()
            .len(),
        accepted,
        "the accepted snapshot remains reopenable"
    );
}

#[tokio::test]
async fn text_and_geometry_only_pdf_annotations_round_trip() {
    let (store, pool, _dir) = temp_store().await;
    let rectangles = vec![
        PageRect::new(1.0, 2.0, 5.0, 4.0).unwrap(),
        PageRect::new(1.0, 5.0, 8.0, 7.0).unwrap(),
    ];
    let text = NewAnnotation {
        id: AnnotationId::new(),
        book_id: None,
        local_path: Some("/books/example.pdf".into()),
        fingerprint: fingerprint(),
        quote: Some(QuoteSelector::new("selected", "before", "after").unwrap()),
        target: AnnotationTarget::Pdf(
            PdfAnchor::new(3, Some((20, 28)), rectangles.clone()).unwrap(),
        ),
        color: HighlightColor::Blue,
        body: None,
        provenance: Some(ImportProvenance {
            source_system: "pdf-native".into(),
            source_id: Some("42".into()),
        }),
    };
    let created = store.create_async(&text).await.unwrap();
    assert_eq!(created.target, text.target);
    assert!(
        sqlx::query(
            "INSERT INTO annotation_pdf_rectangles
                (annotation_id, rect_index, left, bottom, right, top)
             VALUES (?, ?, 0, 0, 1, 1)"
        )
        .bind(created.id.to_string())
        .bind(i64::try_from(MAX_PDF_RECTANGLES).unwrap())
        .execute(&pool)
        .await
        .is_err(),
        "SQLite must reject rectangle indexes outside the bounded read contract"
    );

    let geometry_only = NewAnnotation {
        id: AnnotationId::new(),
        quote: None,
        target: AnnotationTarget::Pdf(PdfAnchor::new(4, None, rectangles).unwrap()),
        provenance: None,
        ..text
    };
    let loaded = store.create_async(&geometry_only).await.unwrap();
    assert!(loaded.quote.is_none());
    assert_eq!(loaded.target, geometry_only.target);
}

#[tokio::test]
async fn delete_creates_a_hidden_tombstone() {
    let (store, _pool, _dir) = temp_store().await;
    let created = store.create_async(&epub_annotation(None)).await.unwrap();

    assert!(store.delete_async(&created.id).await.unwrap());
    assert!(store.get_async(&created.id, false).await.unwrap().is_none());
    let tombstone = store.get_async(&created.id, true).await.unwrap().unwrap();
    assert!(tombstone.deleted_at.is_some());
    assert!(!store.delete_async(&created.id).await.unwrap());
}

#[tokio::test]
async fn concurrent_deletes_never_make_book_listing_fail() {
    let (store, pool, _dir) = temp_store().await;
    let book_id: i64 = sqlx::query_scalar(
        "INSERT INTO books (title, format, file_path) VALUES ('Example', 'epub', '/books/example.epub') RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    let mut ids = Vec::new();
    for _ in 0..32 {
        ids.push(
            store
                .create_async(&epub_annotation(Some(book_id)))
                .await
                .unwrap()
                .id,
        );
    }

    let listing_store = store.clone();
    let listing = tokio::spawn(async move {
        for _ in 0..32 {
            listing_store.list_for_book_async(book_id).await?;
            tokio::task::yield_now().await;
        }
        anyhow::Ok(())
    });
    let deleting_store = store.clone();
    let deleting = tokio::spawn(async move {
        for id in ids {
            deleting_store.delete_async(&id).await?;
            tokio::task::yield_now().await;
        }
        anyhow::Ok(())
    });

    listing.await.unwrap().unwrap();
    deleting.await.unwrap().unwrap();
    assert!(store.list_for_book_async(book_id).await.unwrap().is_empty());
}

#[tokio::test]
async fn invalid_cross_format_payloads_are_rejected_before_writing() {
    let (store, pool, _dir) = temp_store().await;
    let mut epub = epub_annotation(None);
    epub.quote = None;
    assert!(store.create_async(&epub).await.is_err());

    let mut pdf = epub_annotation(None);
    pdf.target = AnnotationTarget::Pdf(
        PdfAnchor::new(0, None, vec![PageRect::new(0.0, 0.0, 1.0, 1.0).unwrap()]).unwrap(),
    );
    assert!(store.create_async(&pdf).await.is_err());
    assert!(PageRect::new(0.0, 0.0, f32::NAN, 1.0).is_err());
    assert!(EpubAnchor::new(0, "../chapter.xhtml", 0, 1).is_err());
    assert!(QuoteSelector::new("   ", "", "").is_err());

    let mut oversized = epub_annotation(None);
    oversized.local_path = Some("x".repeat(MAX_LOCAL_PATH_BYTES + 1));
    assert!(store.create_async(&oversized).await.is_err());
    oversized.local_path = None;
    oversized.body = Some("x".repeat(MAX_ANNOTATION_BODY_SCALARS + 1));
    assert!(store.create_async(&oversized).await.is_err());
    assert!(
        store
            .update_async(
                &oversized.id,
                HighlightColor::Yellow,
                Some(&"x".repeat(MAX_ANNOTATION_BODY_SCALARS + 1))
            )
            .await
            .is_err()
    );
    oversized.body = None;
    oversized.provenance = Some(ImportProvenance {
        source_system: "x".repeat(MAX_PROVENANCE_SYSTEM_BYTES + 1),
        source_id: None,
    });
    assert!(store.create_async(&oversized).await.is_err());
    oversized.provenance = Some(ImportProvenance {
        source_system: "test".into(),
        source_id: Some("x".repeat(MAX_PROVENANCE_ID_BYTES + 1)),
    });
    assert!(store.create_async(&oversized).await.is_err());
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM annotations")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 0, "invalid inputs must be rejected before writing");
}

#[tokio::test]
async fn unknown_required_versions_fail_without_changing_the_record() {
    let (store, pool, _dir) = temp_store().await;
    let created = store.create_async(&epub_annotation(None)).await.unwrap();
    sqlx::query("UPDATE annotations SET anchor_version = 99 WHERE id = ?")
        .bind(created.id.to_string())
        .execute(&pool)
        .await
        .unwrap();

    assert!(store.get_async(&created.id, true).await.is_err());
    let version: i64 = sqlx::query_scalar("SELECT anchor_version FROM annotations WHERE id = ?")
        .bind(created.id.to_string())
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(version, 99);
}

#[tokio::test]
async fn child_insert_failure_rolls_back_the_annotation_transaction() {
    let (store, pool, _dir) = temp_store().await;
    let input = NewAnnotation {
        id: AnnotationId::new(),
        book_id: None,
        local_path: Some("/books/example.pdf".into()),
        fingerprint: fingerprint(),
        quote: None,
        target: AnnotationTarget::Pdf(
            PdfAnchor::new(0, None, vec![PageRect::new(0.0, 0.0, 1.0, 1.0).unwrap()]).unwrap(),
        ),
        color: HighlightColor::Pink,
        body: None,
        provenance: None,
    };
    sqlx::query(&format!(
        "CREATE TRIGGER reject_test_rectangle BEFORE INSERT ON annotation_pdf_rectangles
         WHEN NEW.annotation_id = '{}'
         BEGIN SELECT RAISE(ABORT, 'test rejection'); END",
        input.id
    ))
    .execute(&pool)
    .await
    .unwrap();

    assert!(store.create_async(&input).await.is_err());
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM annotations WHERE id = ?")
        .bind(input.id.to_string())
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 0);
}
