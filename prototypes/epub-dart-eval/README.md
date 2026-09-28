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
                        line-level canonical ranges, pagination, continuous
                        window, selection/copy/highlight projection, capture
                        analysis, adapters (file/clipboard/fonts/images/position)
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
```

The `make test-epub-prototype` and `make measure-epub-prototype` targets at the
repository root wrap these commands.

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
