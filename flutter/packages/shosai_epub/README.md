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
- durable `(spine, scalar)` addresses, resolved TOC locations
  (`resolveTocLocations`) and internal-link resolution (`resolveBookLink`);
- bounded MathML fallback and embedded-font admission (TTF/OTF; WOFF/WOFF2 are
  reported unsupported rather than applied).

## Navigation resolution

The reader serves its Contents panel and its painted internal links from this
package's resolution, so the rules follow the retained implementation:

- `resolveEpubReference` is the production `CanonicalEpubPath::resolve` rule
  set: it rejects a query, multiple fragments, a foreign origin (`//` or a
  scheme), an empty segment, a trailing slash, an encoded separator or dot
  segment, an escape above the archive root and a reference that resolves to the
  archive root, and it decodes the fragment exactly once.
- `resolveTocLocations` returns the entries that resolve to a durable location,
  with the authored depth retained even when a parent entry itself does not
  resolve (a title-only part heading).
- `resolveBookLink` resolves a painted href against the current document
  (`#fragment` stays in the document) and returns `null` for an unknown or empty
  fragment instead of falling back to the chapter start.
- Anchor admission follows the production `record_anchor_name`: an empty or
  over-long name and a name with control characters never become anchors, so
  `#` can never resolve to a position. A trailing marker inside a heading, an
  inline block or a figure caption resolves at that block's end, and a collapsed
  figure records its image's and the image ancestors' anchors, matching the
  production parser's own offsets.

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

- **Aligned 2026-10-02 (`<br/>`, table-cell whitespace, TOC source).** The
  engine now reproduces the retained canonical text for `<br/>` (the
  production collector emits nothing for it), for inline-only table cells
  (one collapsed run through the ported production cell collectors) and for
  text runs around display math inside cells, and the TOC source preference
  below is aligned; chapters whose only divergence was one of these route to
  the Dart renderer now.
- **Suppressed anchors in media-bearing inline cells (residual).** A cell
  whose inline content mixes an image or MathML with an anchor cannot have its
  anchors reproduced from the rendered content (the retained anchor stream
  ignores image alt text and treats MathML as spans), so this port drops that
  cell's descendant anchors instead of publishing an offset it cannot verify.
  The canonical *text* of such cells matches the retained stream. A name
  dropped this way is not offered anywhere in the chapter — even when another
  element carries it — so a fragment link to it resolves to nothing and a
  Contents row that targets it is not offered: the reader's unknown-anchor
  policy, not a wrong target. Separately, a cell whose anchor walk truncated
  at this port's 64-element depth ceiling — a textless truncation is invisible
  to the routing gate, and a partial walk map cannot prove it resolved the
  first occurrence of every name — fails admission (`EpubLimitError`) instead
  of publishing that map; the book stays on the retained renderer, whose
  walkers have no such ceiling. The reader routes by comparing this port's
  canonical stream with the retained one, and the routing suite pins the
  consequence end to end: a book whose only difference from a routing control
  is the span depth is refused at admission and stays retained, while the
  control routes.
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
- **TOC source preference (aligned 2026-10-02).** The TOC source is chosen
  exactly like the retained parser now: the NCX first — the manifest item whose
  media type is `application/x-dtbncx+xml`, with no `.ncx` suffix rule — and
  only then an EPUB 3 nav document, found by the manifest id containing "nav"
  (case-sensitive substring), not by `properties="nav"`. A usable NCX (parseable
  XML with a `<navMap>`, even with no points) suppresses the nav fallback; an
  unparseable NCX or one without a `<navMap>` falls through to the nav
  document. Within a nav document the first `<nav>` in document order is used
  (no `epub:type` preference) and its first descendant `<ol>`. Remaining
  residuals: the production manifest is a `HashMap`, so its NCX candidate is an
  arbitrary one where this port takes the first in manifest order (a documented
  deterministic superset); an NCX entry with an unusable src is resolved with
  the same plain relative-reference rule as production (including its quirk of
  joining the NCX's own directory to a relative src); and the admission
  difference below.
- **TOC error handling.** A nav/NCX entry whose href is unusable is skipped
  individually with a warning; the retained parser abandons that candidate's
  table of contents and falls to the next navigation document when any entry
  fails to resolve. A book with one malformed entry can therefore show more
  rows here than the retained reader shows.
- **Broken navigation XML at read time (residual).** The retained TOC reader
  (`read_archive_entry_cancellable`) validates a selected NCX's UTF-8 and
  lexically inspectable XML — a tolerant shape walk (`check_end_names=false`,
  `allow_unmatched_ends=true`) under byte/depth/text limits — and propagates a
  failure to the whole book (a missing NCX file is skipped before that read);
  it validates a nav document the same way whenever it reads one. Structural
  mismatches that pass that inspection only fail the candidate's own
  `roxmltree` parse, abandoning that candidate for the next navigation
  document, so when the NCX wins, a broken nav document never fails the book
  (verified). This port decodes every TOC byte sequence with malformed-UTF-8
  replacement and no strict read: non-UTF-8 bytes that still yield parseable
  XML stay selected with replacement characters and no warning, and lexically
  malformed XML opens with a warning and the nav fallback (or no table of
  contents) where production fails the book. Disclosed rather than absorbed;
  aligning it is a read/admission change, not a TOC-preference one.

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
