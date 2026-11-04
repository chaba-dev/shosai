# PDF Columns — region analysis (stack PR1)

Acceptance source: [RFD 12, Papers on phones and revised Decisions](https://github.com/chaba-dev/rfds/blob/d9fae4eb30607b4620d09441c6d08b4cbab64425/rfd/0012/README.adoc),
[rfds PR #16](https://github.com/chaba-dev/rfds/pull/16).

This is the nonvisual foundation, not the Columns reading mode. Nothing in
the app calls the analyzer yet, so existing PDF opening, rendering, selection
and Display behavior must stay unchanged. PR2 builds the view; PR3 integrates
it into the reader. Do not treat screenshots of the existing reader as evidence
that Columns is already available.

## Contract for the successors

`PdfEngineDocument.pageGeometry(page)` returns owned immutable text lines,
image-object rectangles and other painted-object bounds (`graphics`, paths and
shadings). `hasUnboundedGraphics` signals an object whose coverage could not be
established. All rectangles are **points in the rotated visible
page, top-left origin**, not unrotated PDF coordinates or display pixels.
Nested Form XObject transforms, CropBox and page rotation are applied by the
engine. Character offsets remain PDFium indices, just like selection/search.
Line text is an unchanged slice of that canonical page text. Physical rows are
grouped against a representative loose glyph, never the accumulated paragraph
union. Their bounds use PDFium's tight painted glyph boxes, exposing actual
inter-row whitespace; the selection surface still uses loose rectangles.

Pass the geometries to `analyzePdfColumns(pages, rightToLeft: document.rightToLeft)`.
The function is pure Dart and does not load PDFium or Flutter. The output is
parallel to the input pages. Retain the input page indices alongside it if
analyzing only a sample. The caller controls sampling and asynchronous lifetime;
the function neither fetches pages nor owns document handles.

Each `PdfColumnPage` has ordered `regions` and `columnCount`. Zero columns means
**one page region at fit width with proven empty margins trimmed**. Unknown
painted coverage retains full-page bounds. Otherwise, bands are top-to-bottom;
columns between bands run left-to-right (reversed for declared R2L). Connected
image/vector/shading components and their labels/cells own figure regions;
tiny contained raster hyphens/underlines stay with their text line. Physical
lines retain their page coordinates and half-open character ranges so the view
can break screens between lines and map selection through an offset and scale.
Figure/table regions are **indivisible** in this stack; their physical lines
are selection geometry, not safe-break promises. PR2 fits them to a screen and
provides crisp detail pinch for figures and fallback pages. Region bounds add
1pt raster padding, limited at neighboring whitespace midpoints, separately
from the tight line bounds used for screen cuts.

Detection is conservative: gutters need three lines per side, a minimum
12pt/1.2-line-height gap, overlapping vertical extent, and substantial column
widths. Spanning text becomes a band; adjacent title lines share a band. A band
owns other text in the same horizontal slice, so ACM author groups are not
read a second time below the title. Textless pages, marginal arXiv stamps,
ordinary ragged paragraphs and uncertain layouts do not manufacture columns.
Recurring text in the outer 10% at the same normalized position on at least two
distinct sampled pages is omitted; numeric/Roman folios may vary. Alternating
heads can recur on facing pages. Single-page analysis cannot establish a head.
There is no OCR or semantic table recognition. Vector components are grouped
geometrically before gutter inference, so plot/table labels cannot invent
columns inside a figure or hide the surrounding body gutter.
Before returning column crops, the analyzer checks that every retained line,
image and other painted-object bound is contained by exactly one region and
does not overlap another crop. Unknown object bounds, uncovered vector ink,
partial intersections or ambiguous overlaps still use a safe page region.
Figure/table labels belong to their component once, not a later text block.
Successors must use the engine geometry unchanged, including its coverage
fields; constructing a text/image-only copy discards the safety contract.

## Ten-rule delivery boundary

| RFD rule | PR1 delivery / successor obligation |
| --- | --- |
| 1. Pieces | Physical lines, gutter groups, image/vector/table components with label ownership, recurring margins. |
| 2. Order | Ordered bands and intervening columns; declared R2L reverses columns only. |
| 3. Size | Point bounds available; PR2 fits each piece and applies shared size steps. |
| 4. Screens | Physical line boxes available; PR2 builds the cross-page strip, line-safe screen breaks, column rules and page bands. |
| 5. Turning | No behavior changed; PR2/PR3 wire zones/swipes and slide/no-animation, never curl the strip. |
| 6. Place | Geometry stays in page points; PR3 persists page + height and restores both modes with the page-outline indicator. |
| 7. Selection, marks, search, links | Original character ranges preserved; PR2/PR3 apply piece offset/scale to existing page-space surfaces. |
| 8. Getting there | PR3 adds Columns/Fit width/Fit page and double-tap entry/exit. |
| 9. Default | Column counts support first-page sampling; PR3 chooses phone defaults and preserves the reader's saved choice. |
| 10. Fall-back | Figure/table pages keep columns. No text/no gutter uses safe trimmed page bounds; unknown coverage retains the full page. PR2 owns fit width and crisp pinch. |

## Verification

`flutter test test/reader/pdf` covers measured Thrift columns/title, a licensed
ACM two-column paper, a single-column arXiv excerpt (including its vertical
identifier), synthetic scan fallback, three columns, R2L, bands/figures,
recurring heads/folios, and raster-checked nested image geometry at all four
rotations with a nonzero CropBox. A first-party four-page PDF also checks every
painted pixel for exactly-once crop coverage: vector art below the body, wider
vector art above its caption, a labeled raster figure, and an axial shading.
All four controls now keep columns and their own figure regions.
Every Thrift page splits, including raster-hyphen pages 2/6/7. Exact-page
ResNet facts cover all 12 pages (including plots, diagrams and tables), with
Attention's 15 one-column pages as negative controls. Optional pinned original
PDFs additionally verify fresh engine extraction and zero omitted/repeated
raster ink; their non-CC originals are not redistributed. The physical-row
regression checks real whitespace cuts on Thrift pages 1/3/4 and unchanged
canonical offsets. Superscripts remain inline.
Corpus attribution, rights and checksums are
in `fixtures/pdf-columns/README.md` and `SHA256SUMS`.

Run `make lint`, `make test`, and the existing production-shell golden harness.
This PR changes no golden baselines. If a later stack PR changes macOS
goldens, regenerate and verify them on the **Mac mini**; Linux cannot certify
macOS text rasterization.
