use shosai_core::document::{Document, RenderedPage};
use shosai_core::pdf::PdfDoc;
use shosai_core::search::search_pages;
use std::path::PathBuf;

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(name)
}

fn generated_pdf(page_options: &str, content: &str) -> Vec<u8> {
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>".to_string(),
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_string(),
        format!(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] {page_options} \
             /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>"
        ),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_string(),
        format!(
            "<< /Length {} >>\nstream\n{content}\nendstream",
            content.len() + 1
        ),
    ];

    let mut pdf = b"%PDF-1.4\n".to_vec();
    let mut offsets = Vec::new();
    for (index, object) in objects.iter().enumerate() {
        offsets.push(pdf.len());
        pdf.extend_from_slice(format!("{} 0 obj\n{object}\nendobj\n", index + 1).as_bytes());
    }
    let xref_offset = pdf.len();
    pdf.extend_from_slice(format!("xref\n0 {}\n", objects.len() + 1).as_bytes());
    pdf.extend_from_slice(b"0000000000 65535 f \n");
    for offset in offsets {
        pdf.extend_from_slice(format!("{offset:010} 00000 n \n").as_bytes());
    }
    pdf.extend_from_slice(
        format!(
            "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref_offset}\n%%EOF\n",
            objects.len() + 1
        )
        .as_bytes(),
    );
    pdf
}

fn render_search_match(doc: &PdfDoc, query: &str) -> (RenderedPage, RenderedPage) {
    let page_text = doc.page_text(0).unwrap();
    let result = search_pages(&[page_text], query)
        .into_iter()
        .next()
        .unwrap_or_else(|| panic!("generated PDF should contain {query:?}"));
    let plain = doc.render_page(0, 1.0).unwrap();
    let highlighted = doc
        .render_page_with_highlights(0, 1.0, &[(result.offset, result.length, true)])
        .unwrap();
    (plain, highlighted)
}

fn changed_pixel_bounds(plain: &RenderedPage, highlighted: &RenderedPage) -> (u32, u32, u32, u32) {
    assert_eq!(
        (plain.width, plain.height),
        (highlighted.width, highlighted.height)
    );
    let mut bounds = (plain.width, plain.height, 0, 0);
    let mut changed = 0;
    let mut changed_dark_text = 0;
    for (pixel_index, (before, after)) in plain
        .pixels
        .chunks_exact(4)
        .zip(highlighted.pixels.chunks_exact(4))
        .enumerate()
    {
        if before != after {
            let x = pixel_index as u32 % plain.width;
            let y = pixel_index as u32 / plain.width;
            bounds.0 = bounds.0.min(x);
            bounds.1 = bounds.1.min(y);
            bounds.2 = bounds.2.max(x);
            bounds.3 = bounds.3.max(y);
            changed += 1;
            if before[0] < 200 || before[1] < 200 || before[2] < 200 {
                changed_dark_text += 1;
            }
        }
    }
    assert!(changed > 0, "highlight must alter rendered pixels");
    assert!(
        changed_dark_text > 0,
        "highlight must overlap the rendered target glyphs"
    );
    bounds
}

#[test]
fn test_open_pdf() {
    let doc = PdfDoc::open(fixture_path("sample.pdf"));
    assert!(doc.is_ok(), "failed to open PDF: {:?}", doc.err());
}

#[test]
fn test_page_count() {
    let doc = PdfDoc::open(fixture_path("sample.pdf")).unwrap();
    assert_eq!(doc.page_count(), 2);
}

#[test]
fn test_page_size() {
    let doc = PdfDoc::open(fixture_path("sample.pdf")).unwrap();

    let (w, h) = doc.page_size(0).unwrap();
    // US Letter: 612 x 792 points
    assert!((w - 612.0).abs() < 1.0, "unexpected width: {w}");
    assert!((h - 792.0).abs() < 1.0, "unexpected height: {h}");

    // Second page should have same dimensions
    let (w2, h2) = doc.page_size(1).unwrap();
    assert!((w2 - 612.0).abs() < 1.0);
    assert!((h2 - 792.0).abs() < 1.0);
}

#[test]
fn test_page_size_out_of_range() {
    let doc = PdfDoc::open(fixture_path("sample.pdf")).unwrap();
    assert!(doc.page_size(99).is_err());
}

#[test]
fn test_render_page() {
    let doc = PdfDoc::open(fixture_path("sample.pdf")).unwrap();
    let page = doc.render_page(0, 1.0).unwrap();

    // Page should have non-zero dimensions
    assert!(page.width > 0, "rendered page width is 0");
    assert!(page.height > 0, "rendered page height is 0");

    // RGBA pixels: width * height * 4 bytes
    assert_eq!(
        page.pixels.len(),
        (page.width * page.height * 4) as usize,
        "pixel buffer size mismatch"
    );
}

#[test]
fn test_render_page_scaled() {
    let doc = PdfDoc::open(fixture_path("sample.pdf")).unwrap();

    let page_1x = doc.render_page(0, 1.0).unwrap();
    let page_2x = doc.render_page(0, 2.0).unwrap();

    // At 2x scale, dimensions should be roughly double
    assert!(
        page_2x.width > page_1x.width,
        "2x width {} should be > 1x width {}",
        page_2x.width,
        page_1x.width
    );
    assert!(
        page_2x.height > page_1x.height,
        "2x height {} should be > 1x height {}",
        page_2x.height,
        page_1x.height
    );
}

#[test]
fn test_render_page_with_search_highlights() {
    let doc = PdfDoc::open(fixture_path("sample.pdf")).unwrap();
    let plain = doc.render_page(0, 1.0).unwrap();
    let highlighted = doc
        .render_page_with_highlights(0, 1.0, &[(0, 20, false)])
        .unwrap();

    assert_eq!(
        (highlighted.width, highlighted.height),
        (plain.width, plain.height)
    );
    assert_ne!(highlighted.pixels, plain.pixels);
}

#[test]
fn test_search_highlights_follow_rotated_page_transforms() {
    for rotation in [90, 270] {
        let pdf = generated_pdf(
            &format!("/Rotate {rotation}"),
            "BT /F1 24 Tf 1 0 0 1 40 120 Tm (TARGET) Tj ET",
        );
        let doc = PdfDoc::from_bytes(pdf).unwrap();
        let (plain, highlighted) = render_search_match(&doc, "TARGET");
        let bounds = changed_pixel_bounds(&plain, &highlighted);

        assert!(bounds.2 < plain.width && bounds.3 < plain.height);
    }
}

#[test]
fn test_search_and_highlights_respect_non_zero_crop_box() {
    let pdf = generated_pdf(
        "/CropBox [100 50 300 200]",
        "BT /F1 20 Tf 1 0 0 1 130 140 Tm (VISIBLE TARGET) Tj \
         1 0 0 1 20 140 Tm (OUTSIDEWORD) Tj \
         1 0 0 1 270 80 Tm (CLIPPEDWORD) Tj \
         1 0 0 1 350 110 Tm (OFFPAGEWORD) Tj ET",
    );
    let doc = PdfDoc::from_bytes(pdf).unwrap();
    let searchable = doc.page_text(0).unwrap();

    assert!(searchable.contains("VISIBLE TARGET"));
    assert!(!searchable.contains("OUTSIDEWORD"));
    assert!(!searchable.contains("CLIPPEDWORD"));
    assert!(!searchable.contains("OFFPAGEWORD"));

    let (plain, highlighted) = render_search_match(&doc, "TARGET");
    changed_pixel_bounds(&plain, &highlighted);
}

#[test]
fn test_search_excludes_off_page_text_without_an_explicit_crop_box() {
    for page_options in ["", "/CropBox [-50 -50 400 250]"] {
        let pdf = generated_pdf(
            page_options,
            "BT /F1 20 Tf 1 0 0 1 40 120 Tm (VISIBLEWORD) Tj \
             1 0 0 1 350 120 Tm (OFFPAGEWORD) Tj ET",
        );
        let doc = PdfDoc::from_bytes(pdf).unwrap();
        let searchable = doc.page_text(0).unwrap();

        assert!(searchable.contains("VISIBLEWORD"));
        assert!(!searchable.contains("OFFPAGEWORD"));
    }
}

#[test]
fn test_search_offsets_survive_generated_line_breaks() {
    let pdf = generated_pdf(
        "",
        "BT /F1 18 Tf 24 TL 1 0 0 1 40 160 Tm (FIRST LINE) Tj T* \
         (SECOND TARGET LINE) Tj T* (THIRD LINE) Tj ET",
    );
    let doc = PdfDoc::from_bytes(pdf).unwrap();
    let searchable = doc.page_text(0).unwrap();
    let target = search_pages(std::slice::from_ref(&searchable), "TARGET")
        .into_iter()
        .next()
        .unwrap();

    assert!(target.offset > "FIRST LINE".chars().count());
    let (plain, highlighted) = render_search_match(&doc, "TARGET");
    let bounds = changed_pixel_bounds(&plain, &highlighted);
    assert!(bounds.3 - bounds.1 < plain.height / 4);
}

#[test]
fn test_search_highlight_is_limited_to_the_target_word() {
    let pdf = generated_pdf(
        "",
        "BT /F1 20 Tf 1 0 0 1 30 120 Tm (PREFIX TARGET SUFFIX) Tj ET",
    );
    let doc = PdfDoc::from_bytes(pdf).unwrap();
    let (plain, highlighted) = render_search_match(&doc, "TARGET");
    let bounds = changed_pixel_bounds(&plain, &highlighted);

    assert!(bounds.2 - bounds.0 < plain.width / 3);
}

#[test]
fn test_render_page_out_of_range() {
    let doc = PdfDoc::open(fixture_path("sample.pdf")).unwrap();
    assert!(doc.render_page(99, 1.0).is_err());
}

#[test]
fn test_metadata() {
    let doc = PdfDoc::open(fixture_path("sample.pdf")).unwrap();
    let _meta = doc.metadata();
    // Our minimal test PDF doesn't have metadata, but the call shouldn't panic
}

#[test]
fn test_from_bytes() {
    let data = std::fs::read(fixture_path("sample.pdf")).unwrap();
    let doc = PdfDoc::from_bytes(data);
    assert!(doc.is_ok(), "from_bytes failed: {:?}", doc.err());
    assert_eq!(doc.unwrap().page_count(), 2);
}

#[test]
fn test_open_nonexistent_file() {
    let result = PdfDoc::open("/nonexistent/path/to/file.pdf");
    assert!(result.is_err());
}
