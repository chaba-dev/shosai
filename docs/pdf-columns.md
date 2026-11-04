# PDF Columns — geometry, strip and reader integration

Acceptance source: [RFD 12, Papers on phones and revised Decisions](https://github.com/chaba-dev/rfds/blob/d9fae4eb30607b4620d09441c6d08b4cbab64425/rfd/0012/README.adoc),
[rfds PR #16](https://github.com/chaba-dev/rfds/pull/16).

PR1 supplies the nonvisual foundation. PR2 adds the Columns reading mode and
explicit Display preference described below; PR3 adds durable place,
selection/marks/search/links, double-tap entry and phone defaults. PR1's
unchanged-reader screenshots are not evidence of the PR2 Columns UI.

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
| 8. Getting there | PR2 adds/persists Columns/Fit width/Fit page; PR3 adds double-tap entry/exit. |
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

## PR2 strip and integration seam

`layoutPdfColumnScreen` consumes nearby `PdfStripPage` metadata and returns an
immutable `PdfStripScreen`: start/next cursors, visible original-page crops,
column/page separators and the next missing page's index. Text rows that overlap
are never split at a screen edge. Paragraphs break at physical rows, with
heading/first-row carry protection. Bands and no-column fallback pages fit the
viewport width; figures/tables fit indivisibly to one screen. Shared Size steps
scale columns from 50% to 100% of their fitted width; short fragments keep their
column's scale rather than magnifying their fonts. The maximum is labeled and
the increase button disabled. Figure/table and fallback-page detail pinch is
separate from Size and always requests fresh clipped PDF pixels.
The strip may cross a column or page boundary within a screen.

Figure headers must travel with their whole diagram, not survive as an orphan
row in the previous screen. The pinned ResNet page-4 regression traverses the
412 × 775 strip and checks all three network headers with the complete figure,
its normal fitted scale, and the adjacent screen. Exact-once ink conservation
alone is not pagination acceptance. The corrected grouping leaves a measured
588.3px (75.9%) preceding blank tail: the 747px figure plus its 28px page band
cannot fit that remainder without changing scale or order. The orphan labels
are resolved, but this large deferral tail remains an explicit visual-acceptance
question, not a no-huge-tail pass. Rebalancing earlier text windows would be a
separate pagination change; this regression does not silently introduce it.

The reader controller loads geometry on demand with three initial pages for
recurring-head sampling, retains nearby geometry, and renders each crop through
`PdfEngineDocument.render(page, scale, clip: rect)`. The returned raster's
`source` includes outward pixel rounding. The controller trims that rounding
when composing a screen at display density; no full-page bitmap is enlarged.
Generation and operation revisions guard every asynchronous adoption, and the
document remains alive until its outstanding render/decode effects drain.

`ReaderModel.pdfColumns` exposes the current immutable screen for PR3.
`PdfStripPiece.toPage` / `fromPage` map between strip-content logical pixels and
rotated original-page points. The view adds `pdfStripHeaderHeight` (32 pt) and
`pdfStripSideInset` (14 pt) outside that space, all within stable device safe
insets. Both axes' scroll offsets in detail mode must also be accounted for by
interaction adapters. `PdfStripPiece.zoomable` identifies figure/page pieces;
`PdfStripScreen.detailZoom` and `strip` preserve the original cursor while a
pinch renders the whole safe region. Pinching back to fit returns to that
screen without changing Size or navigation history. Detail scale is bounded
by the existing 40-million-pixel / 16384px edge admission, for both the outward-
rounded source crop and composed canvas at device density. `detailZoom` stores
the admitted ratio, not the unclamped gesture request. Extremely tall fallback
regions that cannot admit a whole-region enlargement retain their crisp strip.
A screen can contain
more than one page, so mapping must select the hit piece, not assume model.unit
applies to every point. These transforms do not themselves implement selection
or durable restoration.

The explicit fit is `FlutterReaderSettings.pdfFit` / core `PdfFit`, persisted as
`reader.pdf_fit`; null means no explicit choice, allowing PR3's phone default
without erasing a saved choice. The existing `pdfZoom` remains for compatibility.
PR2 does not implement page+y persistence, double-tap entry, phone auto-selection
or annotation/link/search coordinate integration.

## PR2 native evidence and checks

The [PageSpread preview](design-system/components/PageSpread.html) contains
native Linux screenshots of the fitted title/column, column rule and cross-page
band, plus two real desktop recording excerpts: the maximum/submaximum Size
controls, then keyboard screen steps and chrome. The revised captures include
injected 59pt top / 34pt bottom safe insets. Japanese mixed-figure and sharp-detail
captures use the first-party labeled-raster fixture.
[DisplaySettings](design-system/components/DisplaySettings.html)
also includes the native narrow-window sheet. These are Linux at 440 × 900
logical pixels, not an Android device or a browser reader simulation.

`flutter test -d linux integration_test/pdf_columns_test.dart` exercises real
PDFium with Thrift: touch outer-zone steps, middle-zone chrome, swipe and backward
navigation, every-page range naming, safe cutout/home insets, maximum/submaximum
Size, explicit fit callbacks, 200 ms slide-on/instant-off, reduced motion,
fit-width scan fallback, and crisp figure/page pinch with two-axis panning.
The DPR 3 scan controls cover below/above area and edge admission, an exceptionally
tall fallback, and pixel-identical return to a noninitial strip cursor with
backward/forward history. The mixed figure test also runs the Japanese UI. Set
`SHOSAI_COLUMNS_ARTIFACTS` to capture the repaint-boundary PNGs. Unit tests cover
line-safe windows (including indivisible overlapping tall rows), transforms,
band sizing, page/column separators and missing-page loading. Engine crop tests
compare every pixel with a full render and exercise an otherwise inadmissible
high-density page through a small crop.

PR2 passed `make lint`, `make test`, and the production-shell render harness
(11 goldens, zero drift). No golden baselines changed. macOS and Android were
not run; any macOS golden changes in follow-up work require the Darwin Mac mini.
The orb's pinned Mesa 26 cannot expose GLX on Xvfb; the desktop recording used
Nix's `github:NixOS/nixpkgs/nixos-25.05#mesa` (25.0.7), its EGL vendor, driver
directory and library path, with software GL. This capture-only workaround does
not alter application rendering or the project's graphics dependencies.

## PR3 place and interaction integration

Reading state now stores an optional `pdfY` in original rotated-page points
(SQLite migration 14, `reading_state.pdf_y`) and an optional horizontal anchor
`pdfX` (migration 15, `reading_state.pdf_x`). Existing positions without a
height still open at their page. Columns saves the first visible piece's page,
height and horizontal center in original page points. A canonical character
offset remains the primary text anchor; the horizontal coordinate distinguishes
a textless figure from another column at the same height. Fit changes retain that place;
fit-width scrolling updates it through a generation/revision-guarded message.
A page that already fits vertically need not scroll to retain its place.
Entry and restoration normalize overlapping physical lines to a stable boundary,
so repeated fit changes cannot creep upward one line at a time.

`right-column-figure.pdf` is a generated, first-party real PDF with left-column
body text beside a tall raster figure at x317–556, y190–730. The native reader
regressions enter a completely textless figure screen at y350 and check both
Columns → Fit page → Columns and a fresh core reopen. Before the horizontal
anchor, both restore to left-column x54; with it both retain x317 and y350.
The before/after screenshots and moving-pointer fit round-trip recording are
captured on Linux, not a phone runtime.

The strip selection surface keeps each visible page's complete canonical text
but maps only the visible geometry through `PdfStripPiece.fromPage`. A page is
shifted once, even when it appears in several crops. Saved text marks and search
hits use those same offsets; area marks clip in original page space. A selection
crossing pages saves one original-page annotation per intersected page, never
strip pixels. Link hits select the containing piece and use `toPage` before the
existing PDF destination/peek flow. Notes and search jumps enter the region that
contains their original character range. A targeted range reserves leading
space for the overlaid toolbar and selection capsule, accounted for in the
line-safe screen layout, so the hit is visible rather than covered by controls.

Touch double-tap is handled on the actual selectable surface: a fitted page
opens Columns at the tapped column; Columns returns to Fit page, not 2x. A
pending entry/jump is replayed across viewport changes, rather than replaced
by the old screen's position. The single-tap delay is the gesture recognizer's
normal double-tap window; mouse selection and touch long-press remain available.

On a phone with no explicit fit choice and the legacy default zoom, the
controller samples up to the first three pages. Any detected two-column page
selects Columns; otherwise it selects Fit width. It does not persist that
inferred default as an explicit choice. Saved fits and legacy width/manual
choices win; larger screens retain Fit page with optional Columns.

The native Linux integration test covers right-column entry, selection and
canonical note storage, fit changes, reopen, note/search jumps, later-page
restoration, and link peeks/destinations alongside PR2's strip tests. The
asymmetric selection adapter test covers two crops of one page and another page
at a different scale, including horizontal and vertical carets. Core tests cover
the height's storage, validation, reopen and clearing. The PageSpread preview
includes the actual native captures and desktop recording for this integration.
Android and macOS are not certified by Linux evidence; real iPhone verification
belongs to Darwin. No macOS golden baseline is changed here; any such change
requires regeneration and verification on the Darwin Mac mini.
