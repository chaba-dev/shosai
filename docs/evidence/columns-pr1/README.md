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

## Checks

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

## Inline self-review

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
