# shosai_epub

Dart-owned EPUB parsing, normalization, canonical text and durable addresses for
the Shōsai reader. Adopted as the production EPUB engine module on 2026-09-28;
see [the Dart document stack evaluation plan](../../docs/dart-document-stack-evaluation-plan.md).

The reader serves paginated and continuous EPUB content, the Contents panel
and internal links from this package through `lib/reader/epub/`. Flutter owns
layout and painting; this engine supplies the canonical text and addresses
used by the Dart application core's search, bookmarks, annotations and reading
state. PDF uses the separate Dart PDF engine. See the
[current architecture](../../docs/flutter-architecture.md) for these boundaries.

The Rust core and bridge were removed in M3.0 on 2026-10-21. There is no runtime
Rust comparison gate or alternate Rust renderer: admission failures are
reported to the caller, not routed to the old implementation. CBZ is not
supported by this package.

## Scope

- bounded ZIP/OPF/spine/TOC admission and resource limits;
- bounded CSS subset and computed styles;
- XHTML normalization into the content model;
- canonical text stream, scalar checkpoints and anchor offsets, ported from
  the former Rust `search_text()` order, including display-block MathML promotion;
- durable `(spine, scalar)` addresses, resolved TOC locations
  (`resolveTocLocations`) and internal-link resolution (`resolveBookLink`);
- bounded MathML fallback and embedded-font admission (TTF/OTF; WOFF/WOFF2 are
  reported unsupported rather than applied).

## Byte admission

The default ZIP entry ceiling is 64 MiB, with tighter limits at the point a
resource is read: 32 MiB for XHTML chapters/navigation, 16 MiB for fonts,
4 MiB for package/container/NCX XML and SVG, and 1 MiB for CSS. Raster image
payloads may use the full 64 MiB. The renderer uses the same image-byte ceiling;
the existing 16-megapixel engine limit and 64 MiB decoded-raster budget remain.

Archives still have a 4,096-entry limit, a 512 MiB total uncompressed-byte
budget, and a maximum aggregate expansion ratio of 200. These checks happen
before any entry is decompressed, including Unix symlink entries. Only EPUB's
stored/deflated, unencrypted ZIP entries are supported. Each read inflates
directly into a size-bounded buffer and rejects output that disagrees with the
declared size, using archive 4.5.2 or newer's bounded native streaming decoder,
so falsified headers cannot bypass the byte budget. Encoded image
bytes are retained for Flutter; streaming inflation avoids a second unbounded
decompression buffer, not the encoded image's own storage.

`test/support/large_entries_fixture.dart` generates an original landscape PNG
(1,800 × 1,600, over 8 MiB) and an XHTML part over 8 MiB. Tests generate it in
memory rather than committing a large binary. To open the same book in the app,
run `dart run test/support/large_entries_fixture.dart /tmp/large-entries.epub`
from this package. The fixture uses a fixed ZIP timestamp and no third-party
content. The package regression also deflates the large image; Flutter's layout
test decodes the stored variant with the real image codec.

## Navigation resolution

The reader serves its Contents panel and its painted internal links from this
package's resolution. The rules were ported from the former Rust implementation:

- `resolveEpubReference` follows the former `CanonicalEpubPath::resolve` rule
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
- Anchor admission follows the former `record_anchor_name`: an empty or
  over-long name and a name with control characters never become anchors, so
  `#` can never resolve to a position. A trailing marker inside a heading, an
  inline block or a figure caption resolves at that block's end, and a collapsed
  figure records its image's and the image ancestors' anchors, matching the
  former parser's own offsets.

## Known differences from the Rust implementation

The comparisons below record the port's provenance and known differences from
the **removed** Rust implementation. References to the retained/production
parser in this section mean that historical implementation, not a second live
engine. The migration audit in
`docs/dart-document-stack-evaluation-plan.md` recorded byte-identical streams
over its committed fixture corpus (30 books, 52 chapter streams); that was
migration evidence, not a runtime routing guarantee or proof for every book.
The current Dart engine and records use the same Dart canonical stream.
These limitations remain documented; removing the old renderer did not resolve
them or establish new acceptance evidence.

- **Aligned 2026-10-02 (`<br/>`, table-cell whitespace, TOC source).** The
  engine now reproduces the retained canonical text for `<br/>` (the
  production collector emits nothing for it), for inline-only table cells
  (one collapsed run through the ported production cell collectors) and for
  text runs around display math inside cells, and the TOC source preference
  below is aligned. These were parity fixes during the migration.
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
  at this port's 64-element depth ceiling — a partial walk map cannot prove it
  resolved the first occurrence of every name — fails admission
  (`EpubLimitError`) instead of publishing that map. The former Rust walkers
  had no such ceiling; today this is an admission failure, with no
  retained-renderer fallback.
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
- **TOC error handling (aligned 2026-10-02).** A nav/NCX entry whose href or
  src fails to resolve abandons that candidate's whole table of contents, like
  the retained parser's `?` propagation: the NCX falls to the nav document and
  the nav document (the last candidate) leaves the book with no table of
  contents, and entries parsed before the failing one are discarded with it. A
  warning names the rejected reference. An absent target is not an error: a
  navPoint without a `<content>` element or src attribute, and a nav link
  without an href attribute, keep their empty target like the production
  `unwrap_or_default`, and a reference that resolves but names no spine item
  only loses its Contents row. Entry target lookups follow the production
  `Node::attribute` rule (matched by local name when called without a
  namespace, so a declared-prefix `x:href`/`y:src` is the target, taken in
  attribute order; a namespace declaration never is), and entry titles are the
  link's own first child only when that child is text (the production
  `Node::text` rule, with the leading text/CDATA run coalesced the way the
  production parser merges it, an empty leading run still counting as link
  text so the `<span>` fallback does not trigger). Title normalization keeps
  two existing residuals: the port trims Dart's whitespace set (which includes
  U+FEFF) where the production `str::trim` uses the Unicode `White_Space`
  property (which excludes it), and the port's XML reader keeps literal CR/LF
  in text where the production parser normalizes line endings (a `&#13;`
  character reference is preserved by both). Malformed namespace admission stays with the
  read-gate residual above: the production parser rejects a document whose
  attribute prefix is not declared before any lookup, where this port's XML
  reader admits it and resolves the attribute by local name.
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

The standalone evaluation prototype has been retired. Its display-block MathML
promotion omission is fixed here and no longer applies; the remaining known
differences are documented above.

## Checks

```sh
cd packages/shosai_epub
dart pub get
dart analyze
dart test
```

`make lint` and `make test-app` run the same steps (including
`dart pub get`) from the repository root.

The fixture tests read the repository's committed conformance fixtures from
`fixtures/epub-conformance/`, located by walking up from
the test working directory so the package can move.
