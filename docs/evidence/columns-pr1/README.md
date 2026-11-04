# Columns PR1 — native Linux evidence

This is the **existing PDF reader, not a Columns UI**. PR1 adds only page
geometry and a pure Dart analyzer; the app does not call it yet. The recording
shows the original Thrift page, a forward/back page turn, and its text-selection
surface with Note/Copy/Search controls. The images show the original page and
an Abstract selection. They demonstrate that the existing app still reads the
corpus, not the analyzer's ordering (which the unit corpus verifies).

Captured 2026-11-04 from a debug Linux build of the real `ShosaiApp` and
application core, with Thrift and the synthetic scan imported into disposable
local storage. A temporary bootstrap supplied only that storage/import setup;
no reader widgets, bridge results, geometry or rendered pages were mocked.
The software display was Xvfb + Weston (X11 backend, Pixman compositor), with
GTK using Wayland/EGL and Mesa llvmpipe. Xvfb's GLX visuals were unavailable.
ffmpeg recorded the actual pointer and window at 20fps. Desktop padding was
cropped from the PNGs and video; no app content was composited into them.

- `thrift.png`: original first page, two-column paper, page 1 of 8.
- `selection.png`: existing Abstract selection and floating controls.
- `reader-demo.mp4`: original-page/spread navigation and selection state.

## Initial-head checks

- `.agents/dev make lint`: all three analyzers passed; final Flutter analysis
  after the additional line-extraction regression also reported no issues.
- `.agents/dev make test`: script/codegen checks passed, Flutter **1453 passed,
  3 skipped**, EPUB **178 passed**. The command was then OOM-killed in the
  unchanged core test `a copy cancelled mid-way leaves no destination behind`.
  A standalone core rerun hit the same limit; the workload cgroup recorded OOM
  kills. That test creates `List.filled(256 * 1024 * 1024, 7)` before copying.
  No core production or test code is changed by this PR.
- Core rerun excluding only that named test: **265 passed**. This is an explicit
  validation limitation, **not** a claim that the complete `make test` passed.
- Vendored PDFium hook suite: **7 passed**.
- Final `flutter test test/reader/pdf`: **48 passed**, including the added
  canonical-space/gutter regression after the full Flutter run.
- Production-shell golden harness: **11 passed**, zero pixel drift in every
  baseline comparison; repeated independently after the complete Flutter run.
- `make check-fmt`: **254 files, 0 changed**. Corpus SHA-256 checks: all five OK.

## Initial inline self-review

No inline oracle was available; no review agent or thread was created.
Reviewed the ten-rule PR1/successor boundary, unchanged selection/search
indices, nested image transforms and page rotation/CropBox handling, resource
cleanup and limits, R2L ordering, conservative no-gutter fallback, margin
suppression, fixture rights and image/line conservation. Raster-backed tests
check transformed image bounds, not just object counts. The real arXiv stamp
and rotated-text cases exposed false segmentation during implementation and
are covered by the retained corpus.

No golden baselines changed. Any **macOS golden changes in this stack require
regeneration and verification on the Mac mini**; these Linux captures cannot
certify macOS rasterization.

## Oracle P1 follow-up — painted content preservation

Independent review found that the initial crops could omit vector-only figures
and repeat image labels. This is now guarded by painted-object coverage:
PDFium paths/shadings carry bounds alongside images, and unknown/degenerate
coverage is explicit. Every retained line/image/graphic must fit exactly one
crop, without intersecting a second crop; otherwise the analyzer returns the
complete page. Contained labels are owned by the figure, before its caption.

`content-preservation.pdf` is a reproducible, first-party four-page PDF with
two text columns on each page. The retained regression renders it with PDFium
and checks that each painted pixel is covered by exactly one returned crop.
A temporary comparison ran the initial-head analyzer and the fix over those
same pixels, measuring pixels darker than 245 in any RGB channel:

| Case | Before: omitted / repeated pixels | After: omitted / repeated pixels |
| --- | ---: | ---: |
| Vector-only figure below the final body line | 16,800 / 0 | 0 / 0 |
| Wider vector figure above its caption | 2,160 / 0 | 0 / 0 |
| Image with an overlaid label | 0 / 4,512 | 0 / 0 |
| Axial shading outside the text bounds | 16,800 / 0 | 0 / 0 |

The vector/shading pages conservatively fall back; the labeled image retains
two columns. Existing Thrift/ACM column expectations remain unchanged. Pure
geometry controls also cover unknown graphics, safe contained graphics,
partial image/line intersections and label ownership in full-width figures.

Follow-up checks: `make lint check-fmt` passed (all three analyzers; 254 files,
0 changed); `flutter test test/reader/pdf test/visual/production_shell_golden_test.dart`
passed **61 tests** (50 PDF + 11 goldens), with zero golden drift. All six
fixture hashes pass, including after regeneration. The complete `make test`
was not rerun for this follow-up; its initial orb limitation is recorded above.
No UI or golden baseline changed, and the native app demo above remains the
unchanged reader. Independent Oracle re-review/sign-off is still pending.

The following images show actual PDFium pixels masked by the old/new returned
crops, **not a Columns UI**. Both are cropped to the same page-space area;
the retained pixel counts above come from execution, not the illustration.

![Old crops omit the vector-only figure](vector-before.png)

![Whole-page fallback retains the vector-only figure](vector-after.png)
