# shosai_epub

Dart-owned EPUB parsing, normalization, canonical text and durable addresses for
the Shōsai reader. Adopted as the production EPUB engine module on 2026-09-28;
see [the Dart document stack evaluation plan](../../../docs/dart-document-stack-evaluation-plan.md).

This package is **not yet wired into the reader**. The bounded content-service
slice that serves EPUB chapters from it is separate. PDF/CBZ parsing and
rendering, library/import, SQLite storage, bookmarks, annotations, reading state
and search stay on the existing Rust services; the content-service slice replaces
only EPUB chapter content. This module alone does not change any user-visible
behavior.

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

These remain open parity work rather than accepted permanent differences. The
EPUB content-service slice must resolve or explicitly account for them before it
routes reader content, because Rust-owned records (search results, bookmarks,
annotations, reading state) address the Rust canonical stream.

- **Table-cell display math whitespace.** The production table collector
  collapses each text run around display math separately, so
  `<td><p>before <math display="block">…</math> after</p></td>` yields
  `before\n(a)/(b)\nafter\n\n`. This port parses the cell paragraph with the
  chapter rules and yields `before \n(a)/(b)\n after\n\n`; the separators and
  the surrounding blocks agree, the run whitespace does not yet. Pinned by
  `display-block math inside a cell keeps this port whitespace`.
- **MathML fallback breadth.** The common constructs are ported from the
  production bounded rendering, but not every tag arm is proven equivalent
  (`mover`/`munder` currently take their first child where Rust joins children,
  and `mtable` cell joining is unverified).
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
