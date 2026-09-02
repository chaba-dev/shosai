use shosai_core::annotations::{
    AnnotationId, AnnotationStore, AnnotationTarget, DocumentFingerprint, EpubAnchor,
    HighlightColor, ImportProvenance, NewAnnotation, PageRect, PdfAnchor, QuoteSelector,
    normalize_quote_v1, scalar_range_to_utf16,
};
use shosai_core::reading_state::ReadingStateStore;
use tempfile::TempDir;

async fn temp_store() -> (AnnotationStore, sqlx::SqlitePool, TempDir) {
    let dir = TempDir::new().unwrap();
    let state = ReadingStateStore::open_at_async(&dir.path().join("shosai.db"))
        .await
        .unwrap();
    let pool = state.pool().clone();
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
}

#[test]
fn scalar_offsets_convert_explicitly_to_utf16_units() {
    assert_eq!(scalar_range_to_utf16("A😀é", 1..3).unwrap(), 1..4);
    assert!(scalar_range_to_utf16("short", std::ops::Range { start: 4, end: 3 }).is_err());
    assert!(scalar_range_to_utf16("short", 0..6).is_err());
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
async fn text_and_geometry_only_pdf_annotations_round_trip() {
    let (store, _pool, _dir) = temp_store().await;
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
    assert_eq!(store.create_async(&text).await.unwrap().target, text.target);

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
async fn invalid_cross_format_payloads_are_rejected_before_writing() {
    let (store, _pool, _dir) = temp_store().await;
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
