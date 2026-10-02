# Real-book EPUB compatibility pass — 2026-10-02

Owner-authorized pass over the developer's actual EPUB library (72 books)
through the real Rust bridge and the production Flutter reader. The evidence
is two runs: a 72-book bridge/engine-level routing sweep, and a 6-book
production-reader drive. Book identities
are anonymized (`book-01` … `book-72`, stable by content hash order); titles,
authors, paths, and captures stay in a private artifact directory.

- Date: 2026-10-02
- Baseline revision: `8057d9b7575187e69dcf8cae5e46a92da00ff774` (main@origin,
  #143 merged). No concurrent code was pulled into the measurement baseline.
- Host: linux 6.18.46, x64 (Framework 16), 24 cores
- Toolchain: flutter 3.41.5 / Dart 3.11.3 / rustc 1.94.0 (Nix-provided, via
  `.agents/dev`)
- Scope: EPUB reader compatibility. Out of scope: PDF, SQLite migration,
  spread modes, Rust 5B.

## Privacy

The source library (database and managed book files) was never modified: the
main database file and its WAL predate the pass (2026-09-27); read-only SQLite
connections (`mode=ro`, `query_only`) only mapped the shared SHM file. All
testing ran on a disposable copy of the database and private copies of the
book files; highlights and reading positions were saved only to the disposable
database. Book text, titles, authors, source paths, and screenshots are kept
in a repository-ignored private artifact directory and are not reproduced
here.

## Method

1. **Intake** — a SQLite backup-API copy taken through a read-only URI; book
   files copied to private storage. A disposable application database was
   built with only the EPUB rows, whose file paths were rewritten to the
   private copies.
2. **Routing sweep** (all 72 books) — `flutter/test/corpus/
   epub_real_corpus_sweep_test.dart`, opt-in via environment. For every chapter
   (unit) of every book it mirrors the production routing gate
   (`_epubRelayout` / `_epubUnitMatchesRetained`): the engine's canonical
   stream must equal the retained `epub_canonical_text` stream, the bundled
   faces must cover the text, and the chapter's indivisible units must fit the
   bounded-work ceilings. Two calibration controls (a parity fixture must
   route; an over-deep admission fixture must refuse) fail the run on harness
   drift.
3. **Pagination-invariant sweep** (subset of 6 books; harness supports any
   manifest) — `flutter/test/corpus/epub_real_corpus_pagination_test.dart`,
   opt-in via the same manifest variable. For every chapter it runs the
   production Dart flow/pagination (`layoutChapterFlow` + `paginateFlow`) and
   checks the invariants page stepping relies on (ordered page canonical
   starts; every page resolves its own start via `pageOfCanonical`).
   Violations on real books are recorded per book, not asserted; a
   self-authored synthetic control must satisfy the invariants so harness
   drift fails the run. No Rust bridge is needed (the engine parse is pure
   Dart).
4. **Interactive pass** (representative subset) — `flutter/integration_test/
   epub_real_corpus_reader_test.dart`, opt-in via environment. Drives the real
   `ReaderScreen` in the real `ShosaiShell` over the real Rust bridge and the
   disposable database: opens each book, turns pages with the keyboard,
   navigates via the Contents panel, drag-selects/copies/highlights with a
   mouse, changes the font size through the typography panel, resizes the
   viewport, then tears the reader down and reopens the book through a fresh
   bridge — the production "relaunch" path — to verify durable-position
   restore and highlight persistence.
5. **Timing** — engine-reported frame timing (`FrameTiming`
   build/raster/totalSpan via `addTimingsCallback`). Because profile builds
   deliver frame timings in batches (~100 ms), each sample is windowed by
   quiescing delivery, marking the newest delivered vsync timestamp, running
   the action, then keeping only frames whose vsync is newer than the marker;
   a sample with no frames is rejected rather than measured. The kept slice
   is a window of presented frames — it includes the sample's own settling
   pumps and bounds every frame presented during the window; it is not a
   single-action attribution. 3 warmup + 12
   sampled warm page turns per book. Input-dispatch-to-present latency is
   **not reported**: it was not validly measured in this environment (the
   wall-clock alignment of the engine's frame timestamps failed its
   consistency check), and the harness omits the metric rather than reporting
   an invalid one.
6. **Memory** — Dart retained heap only, via the VM service allocation
   profile after a requested service GC; the GC is confirmed per checkpoint by
   the service-GC timestamp advancing (it is a request, not a guarantee). This
   is not process RSS and does not include native (Skia/Rust) allocations; no
   claim about total process memory is made.

Evidence provenance (private, git-ignored): the routing counts combine
`epub_corpus_sweep_final.jsonl` (70 classified books) with the superseding
reruns `book12-book43-final.jsonl` and `book12-retry.jsonl` (which record the
two open-refused outcomes with the later harness); where a book appears in
several files the most recent run wins. Interactive figures come from one
6-book drive (`interactive-final2/interactive-results.jsonl`). The per-sample
page-step trajectories come from three single-book reruns of the same drive
against the same disposable database (book-04- and book-02-only manifests,
successively more instrumented): the book-02 cycle trajectory quoted under
Interactive verification was observed in the first of these reruns, whose
output files were overwritten by the later, more instrumented reruns — it is
reported as an observation from that run, not from a retained artifact; the
retained artifacts record the later reruns' trajectories and the pagination
sweep below. Pagination-invariant counts come from
`pagination-subset/pagination-results.jsonl` (the 6-book interactive subset).
Percentiles are linear
interpolation between adjacent order statistics; memory values are reported in
MiB.

## Corpus coverage

70 of 72 EPUBs were fully classified by the sweep. The other 2 were refused at
open by the retained parser itself — `limitExceeded: EPUB exceeds an opening
resource limit: EPUB parsed stylesheets exceed their source byte budget` —
deterministically on a fresh bridge and fresh database (3 consecutive runs for
book-12; 2 for book-43). The production reader would show the same refusal
opening these books. book-12 had classified cleanly in an earlier pass on the
same baseline, so the refusal's determinism across conditions is flagged for
investigation; the reported counts use the refused outcome (its chapters are
not counted below).

| Property | Value |
|---|---:|
| Books (EPUB) | 72 |
| Classified at open | 70 |
| Refused at open (retained stylesheet byte budget) | 2 |
| Languages | 60 `en`, 12 `en-us` — **no Japanese, no RTL book exists in the corpus** |
| Chapters (units) in classified books | 3,533 |
| Book size, scalars (median / max, census) | 607k / 2.12M |
| Largest chapter | 220,454 scalars |
| Tables | 10,418 (max 73 rows × 13 cols) |
| Images | 4,301 (max 565 in one book) |
| Books with embedded `@font-face` | 37 (2–6 faces) |
| Code blocks | 17,489 |
| Greek/Cyrillic traces | ~12 books |

## Routing breakdown (70 classified books, 3,533 chapters)

Counts describe eligibility under the mirrored routing gate with the bundled
coverage loaded from disk — per finding 1, a packaged app would route none of
them. They are not observations of 3,533 painted chapters; painting was
verified on the 6-book interactive subset.

| Outcome | Chapters | Share |
|---|---:|---:|
| Eligible for the Dart EPUB renderer | 3,114 | 88.1% |
| Canonical mismatch (retained fallback) | 212 | 6.0% |
| Retained-ceiling refusal (fallback; confirmed `limitExceeded`) | 156 | 4.4% |
| Font-uncovered (fallback) | 50 | 1.4% |
| Indivisible-unbounded (fallback) | 1 | 0.03% |

- 24 books are fully eligible (all chapters); 46 classified books have at
  least one fallback chapter.
- By books affected: retained-ceiling 32 books, canonical-mismatch 17,
  font-uncovered 23, indivisible-unbounded 1.
- Retained-ceiling refusals concentrate in the largest books (the 2.12M-scalar
  book has 16 refused chapters); they are the designed bounded-work fallback
  (the retained-side canonical stream ceiling).
- Canonical mismatch: 212 chapters in 17 books fail the byte-exact
  comparison. CRLF inside `<pre>`/`<code>` is the confirmed mechanism for the
  pinned fixture and for matching real-book observations (finding 3); the
  per-chapter causes of the full 212 were not individually established.

## Interactive verification (representative 6-book subset)

Subset: book-01 (694k scalars, 5 ceiling-refused chapters), book-02 (fully
routed), book-03 (CRLF-divergence book), book-04 (font-uncovered rune,
mostly-empty part pages), book-06 (mixed ceiling + CRLF, 1.34M scalars),
book-51 (2.12M scalars, Greek glyphs, 220k-scalar chapter). Profile AOT builds
on Xvfb; every book ran with the production bundled-loader replaced by the
same two faces loaded from disk (finding 1's control), so the Dart renderer
was actually exercised where the gate admits a chapter.

All 6 books: open to a rendered page with a recorded Dart session; the
Contents panel opens with the real TOC (103–755 rows); mouse drag-select, Copy
(from a pre-cleared clipboard) and Yellow highlight work on all 6 books; a
font-size change through the typography panel re-paginates in place; a
viewport resize (895 → 760 → 895 px recorded painted width) relayouts and
restores the same chapter; after a full reader teardown and reopen through a
fresh bridge (production relaunch path), the reader reopens interactive at the
same chapter (`positionRestored` true on all 6 books).

**Keyboard page steps (PageDown) do not reliably advance real books.** Each
sample records the production painter's own page identity (chapter unit +
window page index, and the page's durable canonical start) before and after
the key event; a sample counts only when the painted page changed. Final-run
results, plus two instrumented single-book reruns that log the page's durable
canonical scalar per sample:

- On a small, fully-routed book, PageDown skipped pages (page 0 → page 10),
  then jumped backward (page 12 → page 1) and settled into a deterministic
  cycle (pages 1…10 → 12 → 1) that never reached the next chapter. The
  underlying durable scalar alternated forward and backward exactly with the
  painted page.
- On a second book, steps advanced 3 pages then went back 3 pages, oscillating
  without progress; at other positions in the same run, page turns at four
  large books' restored positions produced no painted change at all (12 of 12
  samples rejected) with no banner.
- Unit-level mechanism, reproduced on a real chapter: a table whose rows'
  cells carry no mapped canonical content yields `FlowTableRowLayout
  .canonicalStart == 0`, so pages containing such rows report
  `canonicalStart == 0` mid-chapter; `pageOfCanonical` (which assumes ordered
  page starts) then misresolves positions — verified directly by paginating
  the real chapter (a mid-chapter page with start 0; an earlier page's own
  start resolving to that later page). The controller's `_epubPageAfter` /
  `_epubPageBefore` derive the step target from that misresolution, so steps
  skip content or move backward. Such a page also reports canonical 0 as its
  durable reading position, so a saved position on it risks restoring to the
  chapter start (not separately reproduced in this slice).
  Pinned by a committed skipped repro test
  (`flutter/test/reader/epub_table_page_anchor_repro_test.dart` with a passing
  control case; self-authored synthetic content; remove the bug case's `skip`
  when fixed).

Where steps did advance (small/medium chapters away from affected tables), the
step's own frames fit a 60 Hz budget (see Measured performance).

**Pagination invariants over the subset.** A pagination-invariant sweep
(`test/corpus/epub_real_corpus_pagination_test.dart`) lays out every chapter
of a manifest book with the production flow/pagination and checks the
invariants page stepping relies on (ordered page starts; every page resolves
its own start). Over the 6-book subset: 62 of 257 chapters in 4 of 6 books
violate at least one invariant — by book: book-04 51 of 107 chapters (120
zero-start regressions — downward transitions into a zero start; consecutive
zero-start pages are not counted — and 467 misresolved pages), book-51 6 of
34, book-01 3 of 15, book-02 2 of 41; book-03 and book-06 are clean. The
subset's PageDown misbehavior was observed on violating books, but a clean
sweep does not certify smooth stepping (book-06 is sweep-clean and still
rejected every turn sample at its restored position), and the sweep does not
attribute each violation to the zero-anchor mechanism individually. The
sweep runs the fixed interactive-viewport configuration (895×640 content
box, 18 pt typography, no images), so its counts are invariant observations
under that configuration rather than a census of painted pages. The
full-corpus run of this sweep is a follow-up (it is parse-dominated, ~25 min
for the 6 subset books).

Verified behavior failures inside the subset (final-run records; earlier-pass
observations noted separately):

- Highlight save fails asynchronously with `bridge buffer exceeds its memory
  budget (limitExceeded)` on the large books where the target chapter is
  at/near the budget: book-01/06/51 failed in the final run, and book-03
  failed in the earlier run but succeeded in the final run, so the boundary is
  flaky. The reader surfaces "Highlight changes were not saved". Where a save
  failed, the annotation count after reopen equals the pre-run baseline
  (nothing persisted); where saves succeeded, the counts persist through the
  reopen and accumulate across runs (book-02 4 → 5, book-03 0 → 1, book-04
  1 → 2).
- Contents navigation: every tapped row targeted a later chapter (chapter
  labels as the reader displays them, 1-based): verified arrival at the
  target on book-02 (32 → 34), book-03 (13 → 15) and book-04 (59 → 76, a
  17-chapter jump). On book-01 (5 → 6), book-06 (11 → 12) and book-51 (5 → 7)
  the target chapter's relayout failed with the fresh banner "Layout failed:
  bridge buffer exceeds its memory budget (limitExceeded)" and the old page
  stayed painted. (With per-sample painted-position waiting added in the
  final run, the earlier book-02 "did not land" observation was an artifact
  of sampling before the jump completed, not a reader defect.)

## Measured performance

Engine-reported frame timing (`FrameTiming`: vsync → raster completion),
Xvfb software raster. The harness requests a 1000×720 viewport; the recorded
painted reader width is 895 px (the shell composition clamps it), shrinking to
760 px and restoring to 895 px on resize. Warm page turns: 3 warmups + 12
samples per book; a sample is kept only when the key event changed the painted
page and produced frames, and each kept sample's window includes cheap forced
settling pumps, so the turn rows below bound *every presented frame during
turn windows* on the books where steps moved, not a single-action attribution.
On the four large books no turn sample qualified (the steps did not move the
painted page — see Interactive verification), so no turn-window claim is made
for them. Font and resize windows are recorded for all 6 books. All values
are milliseconds; percentiles are linear interpolation.

| Operation | n | p50 totalSpan | p95 totalSpan | max totalSpan |
|---|---:|---:|---:|---:|
| Warm page turn (2 of 6 books where steps moved) | 276 | 2.8 | 4.5 | 8.2 |
| — per-book p50 / p95 / max | — | 2.5–3.1 | 4.0–4.9 | 4.9–8.2 |
| Font-size relayout (all 6 books) | 78 | 2.6 | 8.2 | 14.9 |
| Resize relayout (all 6 books) | 192 | 2.8 | 5.6 | 16.6 |

Every reported sample fits a 60 Hz frame budget (16.7 ms); the largest
observed (16.6 ms, a resize sample on the font-uncovered book) is within one
millisecond of it. **Limitations:** software rasterization under Xvfb — no GPU
compositor, so absolute raster times are optimistic; these are engine-frame
durations (vsync → raster completion), not display-presentation times, and
input-to-present latency was not validly measured here — the numbers establish
frame durations only. Turn-window coverage excludes exactly the books whose
steps did not move; no responsiveness claim is made for steps on those books.

Open-to-first-page (profile AOT, real books; dominated by the engine parse;
final-run values):

| Book | Scalars | Open |
|---|---:|---:|
| book-02 | 353k | 0.8 s |
| book-03 | 490k | 3.0 s |
| book-04 | 659k | 6.7 s |
| book-01 | 695k | 101.4 s |
| book-51 | 2.12M | 191.5 s |
| book-06 | 1.34M | 252.5 s |

book-06's open was 279.7 s in the earlier run on the same disposable database
at a different restored position; both are parse-dominated and match its
isolated engine parse (288 s) — i.e. finding 5. The spread across runs (≈ ±10%)
is within one run's noise; the ordering is stable.

Dart retained heap (VM service allocation profile after a requested service
GC, confirmed at every checkpoint; Dart heap only — not RSS, not native):

| Checkpoint | book-01 | book-02 | book-03 | book-04 | book-06 | book-51 |
|---|---:|---:|---:|---:|---:|---:|
| After open | 67.4 | 47.1 | 67.8 | 54.7 | 61.1 | 88.7 |
| After page turns | 67.1 | 46.8 | 66.8 | 54.6 | 60.9 | 88.6 |
| After selection | 81.2 | 62.2 | 81.7 | 63.2 | 84.6 | 137.9 |
| After font change | 68.4 | 49.3 | 68.5 | 57.3 | 62.9 | 90.3 |
| After reopen | 67.2 | 48.1 | 67.3 | 56.2 | 61.3 | 89.0 |

All checkpoints confirmed the requested GC (service-GC timestamp advanced);
values in MiB. No monotonic growth signal across the checkpoints: after the
selection phase (+8.5 to +49.2 MiB over post-open, largest on the 2.12M-scalar
book) the heap returns to its post-open level at the next checkpoint and after
reopen. The selection-phase spike is observed but not root-caused within this
slice.

## Findings (prioritized)

1. **Packaged font coverage can never load — the measured production build
   never routes to the Dart EPUB renderer.** `_bundledFontCoverage` loads
   `../assets/fonts/InterVariable.ttf` / `NotoSansJP-Variable.ttf` through
   `rootBundle`. Those keys exist in the asset manifest (the fonts are
   declared as family assets), but the files are not — and cannot be — placed
   under `flutter_assets/` in the measured Linux desktop bundle (`../`
   escapes it; the bundle's `fonts/` contains only MaterialIcons). The loader
   catches the failure, returns null coverage, and the gate then refuses every
   chapter (`fontCovered` returns false on null). Verified from the production
   reader: without injection the retained fallback painter renders; injecting
   the same two faces through the existing `fontCoverageLoader` test hook
   makes the same book, same build, route (`dartPagePainted=true`, sessions
   recorded). **Consequence: all routing counts above describe the gate as it
   behaves under test harnesses; in the measured packaged build every chapter
   stays on the retained renderer.** Whether other packaging targets (e.g.
   macOS/Windows bundles) share the defect was not verified in this slice.
2. **Page steps are misdirected by pages whose canonical anchor is 0.**
   Pressing PageDown on real books skips pages, jumps backward, and can cycle
   without progress (deterministically reproduced at unit level; see
   Interactive verification). Mechanism: table rows whose cells carry no
   mapped canonical content produce `FlowTableRowLayout.canonicalStart == 0`
   (`FlowTableCellLayout.canonicalStart` is 0 when the cell's block list is
   empty — empty cells are common in real books' layout tables), so
   `FlowPage.canonicalStart` (the minimum over slices) is 0 for any
   mid-chapter page containing such a row; `pageOfCanonical` assumes page
   starts are ordered and misresolves, and the controller's
   `_epubPageAfter`/`_epubPageBefore` then step to the wrong page — including
   backward. Over the 6-book interactive subset, 62 of 257 chapters in 4 of
   the 6 books violate the page-start invariants, and the sweep does not
   attribute each violation to this mechanism individually (the mechanism is
   pinned end-to-end for the fixture case and reproduced on a real chapter).
   Such a
   page also reports canonical 0 as its durable reading position, so a saved
   position on it risks restoring to the chapter start; the save/reopen
   consequence was not separately reproduced in this slice.
   Pinned by the skipped repro test
   `flutter/test/reader/epub_table_page_anchor_repro_test.dart` (with a
   passing control case). This slice does not fix it.
3. **CRLF inside `<pre>`/`<code>` breaks canonical parity.** The engine's
   canonical stream keeps U+000D U+000A inside preformatted code; the retained
   parser emits U+000A. Affected chapters fail the gate and stay retained
   (the mismatch pool is 212 chapters in 17 books; CRLF is the confirmed
   mechanism for the pinned fixture and for matching real-book observations;
   the per-chapter causes of all 212 were not individually established).
   Pinned by a committed minimal self-authored fixture test
   (`flutter/test/corpus/epub_crlf_pre_divergence_test.dart`) asserting that
   CRLF normalization is the whole divergence.
4. **Bridge memory-budget failures on large chapters.** Saving a highlight
    fails asynchronously with `bridge buffer exceeds its memory budget
    (limitExceeded)` on the large subset books (book-01/06/51 in the final
    run; book-03 failed in the earlier run and succeeded in the final run, so
    the boundary is flaky; the reader reports "Highlight changes were not
    saved", and where the save failed the annotation probe after reopen shows
    nothing persisted). The same budget error also breaks navigation: a
    Contents jump into a large chapter relayouts the target chapter, which
    fails with the reader banner "Layout failed: bridge buffer exceeds its
    memory budget" (book-01/06/51 in the final run). The budget is sized
    against the document scalars limit and the failures are chapters at/near
    it (up to 220k scalars). This slice does not fix it.
5. **Engine parse is quadratic in entity-dense chapters.**
   `resolveNamedEntities` (`packages/shosai_epub/lib/src/normalize.dart`)
   copies the remaining string per character (`xhtml.substring(index)` inside
   the per-char loop). Measured (JIT, this host): a synthetic 224k-scalar
   entity-dense chapter parses in 6,865 ms; the linearized form (validated
   byte-identical canonical output — same 31-chapter hash, 1,335,158 scalars —
   against the unpatched engine on a private probe) parses the same input in
   913 ms. Real books are worse (AOT build, larger chapters): 9 of 72 books
   take 60–288 s per open in the sweep, vs. a max of ~7 s after
   linearization. The fix is not applied here (engine changes are owned by the
   parallel TOC-error thread / a later change); the private diff is preserved
   in the artifacts.
6. **Bundled face coverage is narrow.** Only Inter Variable and Noto Sans JP
   Variable are consulted; chapters containing astral runes not covered by
   these faces (e.g. U+10005) are refused (50 chapters in 23 books). This is
   the designed conservative fallback, but it caps the achievable routing
   share.
7. **Two of 72 books are refused at open** by the retained parser's
   stylesheet byte budget (see Corpus coverage): the production reader cannot
   open them at all. The budget's determinism across conditions (book-12
   classified in an earlier pass) is flagged for investigation.

Open-to-first-page on the largest books is slow (final numbers in the table
above: book-01 101.4 s, book-51 191.5 s, book-06 252.5 s), dominated by
finding 5's quadratic parse.

## Minimal reproductions

- Page-step misdirection: committed skipped test above; run
  `cd flutter && flutter test test/reader/epub_table_page_anchor_repro_test.dart`
  with the bug case's `skip` removed to see the invariant violation (page
  start 0 resolving to a later page; the control case stays green).
- Real-chapter footprint: run the pagination sweep over any manifest (see
  Harness) — it records per-book violating chapters and misresolved pages.
- CRLF divergence: committed test above; run
  `cd flutter && flutter test test/corpus/epub_crlf_pre_divergence_test.dart`.
- Quadratic entity resolution: a private synthetic probe (self-authored
  content; preserved in the git-ignored local artifact directory, not
  committed) — the committed report quotes only the measured numbers above.
- Packaged coverage defect: run the interactive harness without
  `SHOSAI_EPUB_INTERACTIVE_FONTS` (retained painter renders) and with it
  (Dart painter renders) on the same profile build; plus the bundle evidence
  (AssetManifest key `../assets/fonts/InterVariable.ttf`, absent file).
- Open refusal: open book-12 or book-43 in the production reader on the
  measured baseline — the retained parser refuses at open with the
  stylesheet byte-budget error (deterministic in the final pass).

## Harness

Both harnesses are opt-in and touch nothing without environment variables.
Run from the repository's `flutter/` directory; with real books the manifest,
output and database paths point into the git-ignored private artifact area:

```sh
# Routing sweep (all books listed in a manifest)
SHOSAI_EPUB_REAL_CORPUS=manifest.json \
SHOSAI_EPUB_CORPUS_OUT=out.jsonl \
  flutter test test/corpus/epub_real_corpus_sweep_test.dart

# Pagination-invariant sweep (records violations; no Rust bridge needed)
SHOSAI_EPUB_REAL_CORPUS=manifest.json \
SHOSAI_EPUB_CORPUS_OUT=out.jsonl \
  flutter test test/corpus/epub_real_corpus_pagination_test.dart

# Interactive production-reader pass
SHOSAI_EPUB_INTERACTIVE_MANIFEST=manifest.json \
SHOSAI_EPUB_INTERACTIVE_DB=disposable.sqlite3 \
SHOSAI_EPUB_INTERACTIVE_OUT=captures/ \
SHOSAI_EPUB_INTERACTIVE_FONTS=../assets/fonts/ \
SHOSAI_EPUB_INTERACTIVE_OPEN_TIMEOUT_MS=900000 \
  flutter drive --driver=integration_test/driver.dart \
  --target=integration_test/epub_real_corpus_reader_test.dart -d linux --profile
```

The open-timeout override is needed for the measured large books (their parse
takes minutes). `SHOSAI_EPUB_INTERACTIVE_FONTS` is the discriminating control
for finding 1: unset, the production bundled loader runs (and, per finding 1,
refuses every chapter); set, the same faces load from disk through the existing
`fontCoverageLoader` test hook and the gate behaves as designed.

## Limitations

- The interactive subset is 6 books chosen for coverage, not a statistical
  sample; sweep counts are complete, interactive behavior is not.
- No real window-manager resize (the harness resizes its shell widget inside
  a fixed Xvfb window; the recorded painted viewport change 895 → 760 → 895 px
  is widget-level); input-to-present latency was not validly measured (see
  Method); memory numbers are Dart-heap-only.
- Turn-window timing covers only the 2 of 6 books whose PageDown steps moved
  the painted page; the 4 large books' steps did not move and are excluded
  (see Interactive verification). Each kept sample's window includes cheap
  forced settling pumps, so turn rows bound all presented frames in the
  window, not a single action's frames.
- Contents-jump failures are captured with the failed-relayout banner; all
  six tapped rows targeted a later chapter (displayed labels 5→6, 11→12 and
  5→7 for the failures; 32→34, 13→15 and 59→76 for the arrivals). An earlier
  book-02 non-arrival was a sampling artifact and is resolved in the final
  run. The retained run predates a later harness fix to the arrival
  classification (stale-banner and already-at-target handling); its
  `contentsJumpArrived` fields were not used to derive any published
  conclusion, and no post-fix six-book re-run was performed.
- The PageDown misdirection (finding 2) was characterized interactively on 3
  of 6 books and reproduced at unit level on one real chapter; the
  pagination-invariant sweep measured its footprint on the 6-book subset
  (62 of 257 chapters) but not on the full 72-book corpus.
- The open refusal of book-12/book-43 contradicts book-12's clean
  classification in an earlier pass on the same baseline; the conditions
  governing the retained stylesheet budget were not isolated in this slice.
- The Japanese/RTL dimension could not be exercised: the library contains no
  such book.