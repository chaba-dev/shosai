# shosai_epub

Dart-owned EPUB parsing, normalization, canonical text and durable addresses for
the Shōsai reader. Adopted as the production EPUB engine module on 2026-09-28;
see [the Dart document stack evaluation plan](../../../docs/dart-document-stack-evaluation-plan.md).

The reader serves paginated EPUB chapter content from this package through
`flutter/lib/reader/epub/` (the content-service slice, 2026-09-28). A chapter is
routed only after its canonical stream is compared with the retained Rust
`search_text()` stream *and* its text is covered by the reader's bundled faces
(a book's own `@font-face` faces are admitted for painting, but they are not an
admission guarantee: whether a face registers, and whether a span selects it, is
decided after the gate). A mismatch, an unavailable comparison, a chapter whose
text needs a script the bundled faces do not carry, or a chapter whose single
indivisible layout unit (one paragraph, list, table or nested container) exceeds
the bounded-work ceilings keeps the retained renderer. PDF/CBZ parsing and rendering, library/import, SQLite storage,
bookmarks, annotations, reading state and search stay on the existing Rust
services.

## Scope

- bounded ZIP/OPF/spine/TOC admission and resource limits;
- bounded CSS subset and computed styles;
- XHTML normalization into the content model;
- canonical text stream, scalar checkpoints and anchor offsets matching the
  retained Rust `search_text()` order, including display-block MathML promotion;
- durable `(spine, scalar)` addresses and TOC entries;
- bounded MathML fallback and embedded-font admission (TTF/OTF; WOFF/WOFF2 are
  reported unsupported rather than applied).

## Known differences from the Rust implementation

These remain open parity work rather than accepted permanent differences.
Rust-owned records (search results, bookmarks, annotations, reading state)
address the Rust canonical stream, so the content-service slice accounts for
every one of them *at routing time*: it compares this package's canonical stream
for a chapter with the retained one and leaves any chapter that diverges (or
whose comparison is unavailable) to the retained renderer. A divergence is
therefore never silently rendered with offsets the store does not share, and it
is not a permanent difference either — closing each item below removes the
fallback for the content it affects. The audit that established the current
state is in the slice report (`docs/dart-document-stack-evaluation-plan.md`);
over the committed fixture corpus (30 books, 52 chapter streams) the two streams
are byte-identical.

- **Table-cell display math whitespace.** The production table collector
  collapses each text run around display math separately, so
  `<td><p>before <math display="block">…</math> after</p></td>` yields
  `before\n(a)/(b)\nafter\n\n`. This port parses the cell paragraph with the
  chapter rules and yields `before \n(a)/(b)\n after\n\n`; the separators and
  the surrounding blocks agree, the run whitespace does not yet. Pinned by
  `display-block math inside a cell keeps this port whitespace`. A chapter
  containing this construct fails the routing comparison and stays on the
  retained renderer.
- **MathML fallback breadth.** The fallback arms were rewritten arm-for-arm from
  `crates/shosai-core/src/epub/math.rs` (including the malformed-construct and
  multi-row `mtable` rules, which regression tests pin from that source), so the
  previously named `mover`/`munder` and `mtable` differences are closed. Constructs
  the Rust arm list does not cover keep the source-order fallback in both
  implementations.
- **CSS subset.** `@media`/`@import`, attribute/pseudo selectors, sibling
  combinators and CSS variables are skipped with warnings; percentage margins
  resolve to zero and `em` widths resolve against the root font size, while the
  Rust cascade is more complete.
- **Nested lists.** Nested lists flatten into the parent item (the Rust parser
  also flattens them, but the whitespace-collapse unit differs slightly).

The prototype's remaining notes are in `prototypes/epub-dart-eval/README.md`;
its display-block MathML promotion omission is fixed here and no longer applies.

## Checks

```sh
cd flutter/packages/shosai_epub
dart pub get
dart analyze
dart test
```

`make lint-flutter` and `make test-flutter` run the same steps (including
`dart pub get`) from the repository root.

The fixture tests read the repository's committed conformance fixtures from
`crates/shosai-core/tests/fixtures/epub-conformance/`, located by walking up from
the test working directory so the package can move.
