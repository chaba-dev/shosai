# PDF Columns — region analysis (stack PR1)

Acceptance source: [RFD 12, Papers on phones and revised Decisions](https://github.com/chaba-dev/rfds/blob/d9fae4eb30607b4620d09441c6d08b4cbab64425/rfd/0012/README.adoc),
[rfds PR #16](https://github.com/chaba-dev/rfds/pull/16).

This is the nonvisual foundation, not the Columns reading mode. Nothing in
the app calls the analyzer yet, so existing PDF opening, rendering, selection
and Display behavior must stay unchanged. PR2 builds the view; PR3 integrates
it into the reader. Do not treat screenshots of the existing reader as evidence
that Columns is already available.

## Contract for the successors

`PdfEngineDocument.pageGeometry(page)` returns owned immutable text lines and
image-object rectangles. All rectangles are **points in the rotated visible
page, top-left origin**, not unrotated PDF coordinates or display pixels.
Nested Form XObject transforms, CropBox and page rotation are applied by the
engine. Character offsets remain PDFium indices, just like selection/search.
Line text is an unchanged slice of that canonical page text.

Pass the geometries to `analyzePdfColumns(pages, rightToLeft: document.rightToLeft)`.
The function is pure Dart and does not load PDFium or Flutter. The output is
parallel to the input pages. Retain the input page indices alongside it if
analyzing only a sample. The caller controls sampling and asynchronous lifetime;
the function neither fetches pages nor owns document handles.

Each `PdfColumnPage` has ordered `regions` and `columnCount`. Zero columns means
**one complete page at fit width**. Otherwise, bands are top-to-bottom; columns
between bands run left-to-right (reversed for declared R2L). Each raster image
owns a figure region, including small image objects used for rules. Physical
lines retain their page coordinates and half-open character ranges so the view
can break screens between lines and map selection through an offset and scale.

Detection is conservative: gutters need three lines per side, a minimum
12pt/1.2-line-height gap, overlapping vertical extent, and substantial column
widths. Spanning text becomes a band; adjacent title lines share a band. A band
owns other text in the same horizontal slice, so ACM author groups are not
read a second time below the title. Textless pages, marginal arXiv stamps,
ordinary ragged paragraphs and uncertain layouts do not manufacture columns.
Recurring text in the outer 10% at the same normalized position on at least two
distinct sampled pages is omitted; numeric/Roman folios may vary. Alternating
heads can recur on facing pages. Single-page analysis cannot establish a head.
Fallback preserves the complete raster, including any printed head/folio.
There is no OCR, semantic table recognition or vector-figure segmentation.

## Ten-rule delivery boundary

| RFD rule | PR1 delivery / successor obligation |
| --- | --- |
| 1. Pieces | Physical lines, gutter groups, image-object regions, recurring margins. |
| 2. Order | Ordered bands and intervening columns; declared R2L reverses columns only. |
| 3. Size | Point bounds available; PR2 fits each piece and applies shared size steps. |
| 4. Screens | Physical line boxes available; PR2 builds the cross-page strip, line-safe screen breaks, column rules and page bands. |
| 5. Turning | No behavior changed; PR2/PR3 wire zones/swipes and slide/no-animation, never curl the strip. |
| 6. Place | Geometry stays in page points; PR3 persists page + height and restores both modes with the page-outline indicator. |
| 7. Selection, marks, search, links | Original character ranges preserved; PR2/PR3 apply piece offset/scale to existing page-space surfaces. |
| 8. Getting there | PR3 adds Columns/Fit width/Fit page and double-tap entry/exit. |
| 9. Default | Column counts support first-page sampling; PR3 chooses phone defaults and preserves the reader's saved choice. |
| 10. Fall-back | Zero columns returns the complete page, including textless scans; PR2 renders it at fit width within the strip. |

## Verification

`flutter test test/reader/pdf` covers measured Thrift columns/title, a licensed
ACM two-column paper, a single-column arXiv excerpt (including its vertical
identifier), synthetic scan fallback, three columns, R2L, bands/figures,
recurring heads/folios, and raster-checked nested image geometry at all four
rotations with a nonzero CropBox. Corpus attribution, rights and checksums are
in `fixtures/pdf-columns/README.md` and `SHA256SUMS`.

Run `make lint`, `make test`, and the existing production-shell golden harness.
This PR changes no golden baselines. If a later stack PR changes macOS
goldens, regenerate and verify them on the **Mac mini**; Linux cannot certify
macOS text rasterization.
