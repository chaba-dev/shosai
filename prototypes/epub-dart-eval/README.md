# Dart EPUB vertical slice — evaluation prototype

**Evaluation artifact, not a production engine.** This directory implements
Phase C of [`docs/dart-document-stack-evaluation-plan.md`](../../docs/dart-document-stack-evaluation-plan.md):
a Dart-owned EPUB parser/normalizer rendered by Flutter layout, exercised against
one rich chapter, one long chapter, a stress chapter, and the repository's
existing difficult-content fixtures. It is not wired into the application, does
not change the architecture rules in
[`docs/flutter-architecture.md`](../../docs/flutter-architecture.md), and does
not authorize adoption. Results and reproduction steps live in
[EVIDENCE.md](EVIDENCE.md).

## Layout

```
packages/shosai_epub/   pure Dart: ZIP/OPF/spine/TOC, bounded CSS cascade,
                        XHTML normalization, canonical text stream + scalar
                        checkpoints, durable addresses, MathML fallback
lib/reader/             Flutter: Elm-style controller, flow layout with
                        line-level canonical ranges, progressive windowed
                        layout (bounded batches, cancellation, LRU reuse),
                        pagination, continuous window, selection/copy/highlight
                        projection, capture analysis, adapters
lib/main.dart           interactive app (fixture picker → reader)
lib/measure_main.dart   measurement harness (frame latencies, RSS, captures)
tool/generate_fixtures.py  deterministic fixture generator (+ SHA256SUMS)
tool/measure.sh         release bundle + Xvfb measurement run
test/                   layout/pagination/selection, controller/Elm, captures
fixtures/               generated rich/long/stress chapters
```

## Run it

From the repository root, inside the dev shell (`.agents/dev`):

```sh
# tests (engine + prototype)
.agents/dev bash -lc 'cd prototypes/epub-dart-eval && flutter test'
.agents/dev bash -lc 'cd prototypes/epub-dart-eval/packages/shosai_epub && dart test'

# interactive app
.agents/dev bash -lc 'cd prototypes/epub-dart-eval && flutter run -d linux'

# fixtures (deterministic; verifies recorded hashes)
.agents/dev bash -lc 'cd prototypes/epub-dart-eval && python3 tool/generate_fixtures.py --check'

# measurements (builds a release bundle, runs under Xvfb)
.agents/dev bash -lc 'cd prototypes/epub-dart-eval && bash tool/measure.sh'

# eager vs progressive comparison (one strategy per run)
.agents/dev bash -lc 'cd prototypes/epub-dart-eval && \
  SHOSAI_MEASURE_LAYOUT=eager bash tool/measure.sh'
```

The `make test-epub-prototype` and `make measure-epub-prototype` targets at the
repository root wrap these commands.

## Progressive layout (follow-up experiment)

The reader installs a **window** around the durable location first and extends
it in bounded batches that yield to the event loop, instead of measuring the
whole chapter before showing anything:

- `ChapterLayoutSession` measures a contiguous node range; the priority window
  covers ~2.5 viewports from the requested location, then forward and backward
  batches fill the rest (8 ms / 24 nodes per batch, 1 ms yield).
- Cancellation is checked at every batch boundary; a superseded request's
  measured blocks stay in a bounded LRU cache keyed by chapter, width,
  typography and admitted images (mode-independent), so a burst that returns to
  a measured configuration installs with zero layout work.
- The model reports `layoutComplete`; while false the footer shows durable
  progress ("Laying out — N%") instead of a page total, and the page ordinal is
  window-local until the fill reaches the chapter start.
- `SHOSAI_MEASURE_LAYOUT=eager|progressive` runs the comparison;
  `EVIDENCE.md` holds the measured table and limits.

Measured on one runner (release bundle, Xvfb, software rasterization, one
session): the 606k-scalar chapter is usable in 120 ms instead of 300 ms with a
longest UI-thread block of 24 ms instead of 173 ms; a new session at 85 % is
usable in 123 ms instead of 298 ms; relayouts that return to a measured
typography cost the 80 ms coalescing delay and no layout work. A single
120k-scalar paragraph used to stall ~1 s; profiling showed that was the
prototype's own per-line boundary and mapping loops, not Flutter shaping
(~29 ms), and after fixing both the fixture is usable in ~0.17 s with a ~45 ms
longest block.

## What the slice demonstrates

| Requirement | Where |
| --- | --- |
| Headings and styled text | `lib/reader/layout/flow.dart`, captures `rich-chapter-*` |
| Lists (ordered/unordered) | same; generated markers, canonical ranges preserved |
| Images and a basic table | `_layoutImage`, `_layoutTable`; `colspan`/`rowspan` grid, header rows, row-level page splits |
| Embedded fonts | `EpubFontRegistrar`; TTF/OTF only (WOFF/WOFF2 reported unsupported) |
| Japanese and mixed-direction text | `Noto Sans JP` fallback, RTL paragraphs, bidi line ranges from caret probes |
| Paginated and continuous modes | `lib/reader/layout/pages.dart`; no missing/duplicated content tests |
| Selection/copy and highlight projection | `lib/reader/geometry.dart`; same painters for pixels, hit testing and boxes |
| TOC/internal navigation | engine TOC (nav + NCX) → durable `(spine, scalar)`; fragment links |
| Stable new-session locations | `EpubPositionStore`; restored across resize, font-size and reopen tests |
| Bounded rendering | per-line pagination, continuous window painter, tile arithmetic |
| Content-aware captures | `lib/reader/capture.dart`; a blank placeholder test must fail |

## Explicit limitations

These are prototype limits, not claims about what a Dart engine could do, and
not a silent reduction of the shipping requirements:

- **No persistence engine.** New-session locations use a JSON
  `EpubPositionStore` (the interactive app writes
  `artifacts/positions/position-*.json`; tests use an in-memory store). SQLite is
  a separate investigation and is not exercised, so "reopen" evidence is
  controller reconstruction with a shared store, not a database round trip.
- **No annotations/bookmarks/search/notes.** Selection, copy and in-memory
  highlights only.
- **Layout runs on the UI thread.** `TextPainter`/`dart:ui` are main-isolate
  bound, so a Dart-owned layout cannot move to a background isolate the way the
  Rust renderer can. Relayout latency is therefore user-visible work on the UI
  thread (measured in EVIDENCE.md).
- **CSS subset.** Type/class/id/universal/descendant/child selectors,
  `!important`, inline style, and the properties the model can express.
  `@media`, attribute/pseudo selectors, sibling combinators, CSS variables and
  colour/background properties are ignored; unsupported properties and at-rules
  are reported as warnings, not silently applied.
- **MathML is a text fallback.** The bounded expression tree is retained but
  only the readable fallback is laid out; no fraction/radical/script geometry.
- **Nested tables** fall back to their canonical text inside a cell; **nested
  lists** flatten into the parent item (the Rust normalizer flattens them too).
- **Images inside table cells** render as their alt text; image painting in
  cells is not implemented.
- **Over-tall table rows** are placed clipped and counted in
  `PaginatedChapter.overflowPages` rather than split at line boundaries.
- **Script coverage.** The bundled Inter/Noto Sans JP faces do not cover Hebrew
  or Arabic; the prototype registers host faces (documented in
  `lib/reader/script_fonts.dart`) so bidi layout can be inspected. Production
  must bundle a covering face or rely on EPUB-embedded fonts. Emoji remain
  uncovered.
- **Continuous mode memory** scales with the chapter (EVIDENCE.md reports RSS
  under software rendering); the visible-window painter is bounded, but the
  retained `TextPainter` set is not and the harness cannot attribute the growth
  further.
- **Canonical parity is incomplete** for display-block MathML inside a
  paragraph (see the deviation below), and the prototype does not attempt the
  Rust `search_text()` order for every unsupported construct.
- **Single window, single document.** No tabs, no multi-document session, no
  spread-aware hit testing beyond the two-column rule.

## Normalizer deviations from the Rust reference

Ported faithfully: canonical text stream order, anchors, table cell separators,
whitespace collapsing, MathML fallback strings, image alt handling, CSS
inheritance basics, TTF/OTF/WOFF admission classification.

Deliberately different, and asserted as such in
`packages/shosai_epub/test/normalize_test.dart`:

- display-block MathML inside a paragraph is **not** promoted into its own node,
  so its generated separators are absent from the canonical stream;
- `@media`/`@import` and unsupported selectors are skipped with warnings instead
  of a full cascade implementation;
- percentage margins resolve to zero and `em` widths resolve against the root
  font size (the Rust cascade is more complete).
