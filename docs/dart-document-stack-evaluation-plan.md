# Dart document stack evaluation plan

Status: **EPUB adoption decision recorded 2026-09-28; PDF and SQLite remain
unselected.** The owner adopted a Dart-owned EPUB parser/normalizer with Flutter
layout, integrated incrementally behind the retained reader UI (see
[Adoption decision](#adoption-decision-2026-09-28)). This document does not select
a PDF engine, adopt Dart SQLite, authorize a rewrite of retained behavior, or
approve baselines. Every production gate below is still a gate, and no restoration
package is accepted because the architecture changed.

## Continue the parity work; preserve the Flutter UI

The owner directs us to continue **4B and the existing
[Flutter UI restoration plan](flutter-ui-restoration-plan.md)** for now.
[PR #130](https://github.com/chaba-dev/shosai/pull/130) remains the reader-chrome
delivery path. This evaluation is not a prerequisite for its review or a reason
to defer its correctness fixes. Its visual, platform and reference acceptance
gates remain separate from engine selection. Transition polishing also remains
separate from this evaluation.

Preserve the established Flutter UI, localization, typography, accessibility and
typed controller/message/effect boundaries. The project is unannounced and not
live: **compatibility with old database schemas, persisted anchors or Rust
implementation details is not required**. Rust is a behavioral reference, not a
requirement to reproduce every internal abstraction. Good reading behavior and
reliable storage remain requirements; discarding old data does not authorize
discarding user-facing capabilities or deleting existing development data without
an explicit reset decision.

The 2026-09-28 decision amended [architecture rules](flutter-architecture.md) 6
and 7 for EPUB only, and recorded supersessions in the applicable
[RFD 4](../rfd/0004/README.adoc), [RFD 6](../rfd/0006/README.adoc), restoration and
renderer-contract documents. Parsing, layout, anchors and persistence remain
Rust-owned for PDF and CBZ, and Rust keeps storage, records and its other current
services for every format until a separate decision replaces them. Adoption is a
direction with production gates, not an assertion of completed parity; this
document does not declare planned capabilities shipped.

## What the investigations established

### PDF: two viable engines, incomplete reader validation

The isolated comparison built release applications on Linux and macOS with
Flutter 3.41.5 / Dart 3.11.3. Both ran offline on macOS. The tested corpus contains
13 fixtures, mostly generated: vector reference pages, embedded Latin/CJK fonts,
rotation, images/transparency, an 80-page document, links/outlines, encryption and
malformed inputs. It is not representative proof for arbitrary PDFs.

| Candidate | Tested configuration | Findings and costs |
| --- | --- | --- |
| [pdfrx](https://pub.dev/packages/pdfrx/versions/2.4.7) | 2.4.7, pdfrx_engine 0.4.5, PDFium chromium/7811 | Dart-owned native PDFium; no Rust render round-trip. 2.4.8 did not resolve against the SDK's pinned `meta`. Native assets/framework provisioning remains. |
| [dart-pdf](https://github.com/ben-milanko/dart-pdf) / dart_pdf_editor | 5.0.0 with a documented prototype-only patch | Actual pure-Dart parsing/rendering, selection and search APIs. Published code did not compile on the pinned Flutter (`onReorderItem`); the prototype adapts the older callback's index semantics. Full viewer package adds Linux `libsecret` through secure storage. Engine-only integration is a separate, untested option. |

Across 108 rendered pages, dimensions matched; 12 vector pages were
pixel-identical. Inspected Latin/CJK, rotation and transparency output showed no
meaningful content differences. Text/search/outline/link checks agreed within
the exercised cases, allowing line-ending and page-index conventions. PDFium
rejected a truncated file; the Dart engine accepted it as blank pages.

Warm rasterization generally favored pdfrx, especially on macOS. These are
engine-raster timings, **not page-turn experience or first-displayed-frame
measurements**. There is no established overall memory winner.

The following corrections are part of the evidence, not optional footnotes:

- Early Dart timings included PNG encoding; corrected comparisons separate it.
- Early pdfrx memory runs omitted bitmap disposal. Corrected per-document results
  vary; Linux and macOS memory metrics are not directly comparable.
- All first-displayed-frame timings are invalid: the detector accepted a blank
  white placeholder, and capture awaits also stalled.
- Two fixture hashes were stale. The encrypted fixture originally used identical
  owner/user passwords, so it did not exercise restricted user permissions.
  Corrected bytes and provenance were retained; some archived probes inspect
  only the first four pages, so totals must not be treated as full-document data.
- The corrected encrypted fixture reproduces wrong permission-bit decoding in
  pdfrx_engine 0.4.5 on both platforms. The Dart candidate exposes no permission
  API. Whether Shosai enforces document copy/print restrictions is a product
  decision; the incorrect getters are independently a defect. No upstream issue
  or production patch has been authorized by this plan.
- Cross-platform maximum pixel differences are lower than engine-to-engine
  maxima on the tested corpus. Comparing maxima does not establish a per-page
  ordering or a general law about platform rendering.

Native pointer/keyboard interaction, paginated/spread presentation, AES and
broader real-world document coverage remain open. Linux ran under Xvfb/llvmpipe;
the macOS session was locked with the display asleep. Neither establishes a
native interactive pass. macOS prototype bundles were ad-hoc signed with the app
sandbox disabled, not validated distribution packages.

### SQLite: feasible API replacement, packaging still needs a gate

The investigation counted 11 tables and 16 migrations. Disposable probes covered
transactions, WAL, background-isolate access and a basic schema upgrade. Current
document search uses the document engines; library search uses SQL `LIKE`.
There is no demonstrated SQLite FTS requirement.

Start by evaluating direct [sqlite3](https://pub.dev/packages/sqlite3) with
explicit SQL. [Drift](https://drift.simonbinder.eu/) is a valid alternative for
typed queries and migration tooling; reactive APIs can feed controller messages
and are not inherently incompatible with Elm. Code generation and toolchain
constraints must justify their cost. `sqflite_common_ffi` uses sqlite3 underneath
and has no demonstrated advantage here.

On the pinned toolchain, probes resolved sqlite3 3.5.2; newer dependencies hit
SDK constraints. A Linux app bundled SQLite but could not load it until the
bundle library directory was added to the loader path. This establishes a
packaging problem and one working experiment, not a proven final fix or a
general Nix diagnosis. macOS packaging was not exercised. Relevant upstream
reports: [Flutter #182682](https://github.com/flutter/flutter/issues/182682) and
[sqlite3.dart #346](https://github.com/simolus3/sqlite3.dart/issues/346).

### EPUB: custom layout is the main unknown

No suitable drop-in renderer was found in the examined shortlist for the desired
desktop reading experience. This is not a finding that Dart EPUB rendering is
impossible. Parsing ZIP/XML/HTML can use existing packages; Flutter supplies
shaping, text layout and selection primitives, not an EPUB pagination engine.

Evaluate two boundaries: Flutter layout over Rust's normalized document tree,
or a fully Dart-owned parser/normalizer/layout engine. The former may reduce
render coupling sooner; the latter removes more bridge dependencies. Both need
explicit CSS/resource support, pagination and continuous modes, selection
geometry, stable locations, CJK/bidi handling and bounded memory. Keeping Rust
normalization may simplify position mapping but does not guarantee compatibility
or correctness. Old stored-anchor compatibility is not a gate for either option.

This was source research, not a working EPUB prototype. The book-specific Rust
relayout failure reported during 4B remains undiagnosed; better error messages
do not fix it, and a Dart migration is not proven to avoid it. Do not derive a
rewrite schedule from current Rust line counts.

### Phase C result: Dart EPUB vertical slice (prototype)

The isolated prototype in `prototypes/epub-dart-eval/` implements a fully
Dart-owned parser/normalizer (`packages/shosai_epub/`) and a Flutter layout
(`lib/reader/`) over one rich chapter, one 103k-scalar chapter, a 606k-scalar
stress chapter, and the existing difficult-content fixtures. It is an evaluation
artifact: it is not wired into the application, it did not amend
[architecture rules](flutter-architecture.md), and **no adoption decision was
recorded when the prototype merged**. (The owner recorded one on 2026-09-28; see
[Adoption decision](#adoption-decision-2026-09-28).) Its evidence, reproduction
commands, measurements and explicit
limitations are in
[`prototypes/epub-dart-eval/EVIDENCE.md`](../prototypes/epub-dart-eval/EVIDENCE.md)
and [`README.md`](../prototypes/epub-dart-eval/README.md).

What the slice established:

- Parsing, canonical text, anchors, tables, lists, images, MathML fallback,
  embedded-font admission (TTF/OTF), TOC and durable `(spine, scalar)` positions
  can be Dart-owned; the prototype's canonical stream and anchor offsets are
  cross-checked against ported Rust test expectations, including one documented
  deviation (display-block math promotion).
- Flutter layout can produce paginated and continuous reading with selection,
  copy, highlight projection and TOC navigation where pixels, hit testing and
  selection geometry come from the same `TextPainter`s. Content-aware captures
  (and a blank-placeholder rejection test) back the visual evidence.
- The dominant cost is layout on the UI thread: ~40–70 ms of layout work for
  a 103k-scalar chapter and ~0.5–0.65 s for 606k scalars in the release bundle
  under software rasterization (cold open 790 ms state / 1.05 s verified
  capture for the 606k fixture). Warm page turns are cheap because composition
  is precomputed. Continuous-mode RSS snapshots are higher than the paginated
  ones (long 294→309 MiB, stress 389→480 MiB) but the run cannot attribute that
  to the mode: relayouts intervene and RSS is not retained heap. The prototype has
  no isolate strategy for `dart:ui` text layout.
- Unsupported or unproven: real-world CSS breadth, MathML geometry, WOFF/WOFF2
  and emoji fonts, over-tall table-row splitting, and retained-heap attribution
  (RSS is current resident memory, not retained memory).

Follow-up (progressive layout, same prototype). The reader now installs a
window around the durable location first and extends it in bounded batches that
yield, cancels superseded work at batch boundaries and reuses still-valid
measured blocks from a bounded cache. On one runner the 606k-scalar chapter
became usable in 120 ms instead of 300 ms with a longest UI-thread block of
24 ms instead of 173 ms; a new session at 85 % was usable in 123 ms instead of
298 ms; relayouts returning to a measured typography cost the 80 ms coalescing
delay and no layout work. A 120k-scalar single paragraph initially stalled
~1 s; profiling attributed that to the prototype's per-line boundary and
canonical-mapping loops (Flutter shaping is ~29 ms), and after fixing both the
fixture is usable in ~0.17 s. The paragraph remains one indivisible shaping
call, which bounds the worst case. Numbers, method and limits
are in the prototype's `EVIDENCE.md`.

Recommendation carried to the adoption decision: **insufficient evidence to
choose full Dart or hybrid, and no evidence that retaining Rust is worse**. The
slice supports continuing with the existing Rust path while a bounded follow-up
answers the two open questions that actually decide the boundary — whether
Dart-owned layout can meet the relayout/UX budget on the UI thread, and whether
a hybrid (Rust normalization + Flutter layout) avoids the canonical-mapping
costs this prototype paid. That follow-up is not authorized by this plan. The
owner's 2026-09-28 decision below resolves the boundary question in favor of
adoption; this recommendation is retained as the evaluation's actual conclusion,
not rewritten into evidence that did not exist.

### Adoption decision (2026-09-28)

The owner **adopted** the evaluation's proposed direction: **Dart-owned EPUB
parsing and normalization with Flutter layout**, followed by incremental
production integration behind the existing reader UI. The decision was taken in
the [adoption thread](https://ampcode.com/threads/T-01a0e675-f4f2-7202-8eef-bdd8ca70b093)
after [PR #135](https://github.com/chaba-dev/shosai/pull/135) and
[PR #136](https://github.com/chaba-dev/shosai/pull/136) merged the Phase C slice
and its progressive-layout follow-up at
[0a2f6a02](https://github.com/chaba-dev/shosai/commit/0a2f6a0285733e77cf8c4a708992285610996bc2).
It is a direction with production gates, not an assertion of completed parity.

What the decision selects, and what it does not:

- **Selected:** EPUB parsing, normalization, canonical text/anchors, CSS subset,
  resource admission for rendering, and Flutter layout of EPUB chapters. Flutter
  owns presentation, gestures, focus, navigation and platform adapters as before.
- **Retained in Rust:** library and import, SQLite storage, bookmarks,
  annotations and reading state, search, PDF and CBZ parsing/rendering, and any
  remaining consumers of the current EPUB services until a bounded slice replaces
  them. Rust remains a behavioral reference; its internal abstractions are not
  reproduced for their own sake.
- **Not selected:** PDF engine choice and Dart SQLite. They remain separate,
  unselected decisions and their proposed phases below are unchanged.
- **Not authorized:** deleting development data, incompatible saves, or two
  writers to the same database. The project is unannounced, so old schemas and
  persisted anchors need no migration, but retained persistence stays the only
  owner of every transaction until its replacement slice explicitly takes over.
- **Not resumed:** Rust package **5B** (core pagination, bridge transport and
  measured prototype). Its local workspace `shosai-5b-pagination` is paused
  reference work; the restoration plan records it as superseded rather than
  accepted. Historical evidence and package counts are preserved.

Production gates carried by the decision. A gate is satisfied only by evidence
at a named revision; a passing prototype test is not production acceptance:

1. Representative real books, including Japanese and mixed-direction text and
   documents with images and tables. Licensed or otherwise permitted local
   material only; corpus and access limitations are documented rather than
   replaced with generated fixtures that manufacture a pass.
2. Correctness for over-tall table rows, font admission/fallback, and scroll
   position (durable location ↔ rendered position, including reopen).
3. Real frame responsiveness and bounded retained-memory verification. Timer-gap
   probes are not presented-frame timing, and RSS is not retained heap; a claim
   may not upgrade either measurement into what it is not.
4. Existing reader interaction, selection, navigation and restoration coverage
   stays green through the replacement, and PDF/CBZ behavior is untouched.

Which gates a bounded slice owns, and which remain open, is recorded with the
slice. The first slice after this decision is the production engine module and
its boundary; it does not enable replacement broadly. The remaining gates stay
explicit before EPUB routing changes for users, and no partial integration is
reported as whole EPUB adoption.

The decision also fixes the incremental sequence: architecture and explicit
production gates are recorded first (this document, the architecture rules, the
RFD amendments and the restoration plan), then bounded implementation PRs, one
commit per PR, each stacked on the previous one. Package acceptance stays with
the [restoration plan](flutter-ui-restoration-plan.md); recording a decision does
not tick any package checkbox.

### The adopted module boundary

The smallest coherent boundary that replaces the EPUB service behind the
retained UI is the **EPUB document content service**: the operations that turn a
stored EPUB resource into the reader's rendered chapter and its selection
geometry. It is implemented in Dart and consumed through the existing
controller-owned effect pattern; the retained UI (chrome, panels, tabs,
selection overlays, annotation cards, search bar, typography controls,
restoration) is not replaced.

| Boundary operation | Adopted owner | Notes |
| --- | --- | --- |
| EPUB parse/admission (ZIP, OPF, spine, TOC, resources) | Dart engine | Bounded by the same admission/limit policy; no second parser in Flutter widgets. |
| Chapter normalization and canonical text | Dart engine | Must match the retained canonical stream (Rust `search_text()` order) for offsets that Rust still stores; the prototype's display-block MathML deviation is fixed, not carried forward. |
| Chapter layout, pagination and continuous windows | Flutter, over the Dart layout | `TextPainter` layout; one layout produces pixels, hit zones, carets and selection rects. |
| Rendered chapter pixels and selection geometry | Flutter | Delivered to the reader through the controller, not by a widget-owned effect. |
| Durable `(spine, scalar)` locations | Dart engine computes and maps them; Rust persists | The anchor schema, quote/context recovery, annotation resolution and reading-state records stay Rust-owned and unchanged. |
| Bookmarks, annotations, reading state, search | Rust | Unchanged stores; Rust remains the only database writer while the slice is integrated. |
| PDF/CBZ parsing, rendering, geometry | Rust | Untouched by this decision. |

The boundary is deliberately at the document-content level rather than the
whole reader service: it is the smallest seam that removes the EPUB bridge
round-trip while keeping every retained capability's storage and records intact.
A later slice may move search, or the durable anchor store and annotation
resolution, into the engine, but that is a separate decision with its own parity
evidence.

### Production integration sequence

Each slice is one commit and one reviewable PR; later slices stack on the
previous branch. Slices report which production gates they close and which
remain open.

| Slice | Deliverable | Gates it owns |
| --- | --- | --- |
| 1. Architecture and gates (docs only) | This decision, the amended architecture rules, RFD amendments, restoration-plan disposition of 5B, and the boundary above | None. Recording the decision closes no gate; no package is accepted. |
| 2. Production Dart EPUB engine | `shosai_epub` as an app-owned pure-Dart package: archive/OPF/spine/TOC, bounded CSS subset, XHTML normalization, canonical text and scalar checkpoints, durable addresses, MathML fallback, limits. Ported Rust-derived expectations plus canonical parity with the retained stream. No reader routing change. | Engine-level correctness and canonical parity only. No user-visible capability changes, so no interaction/visual gate is claimed. |
| 3. EPUB content service behind the retained UI | The Flutter layout module and the controller-owned adapter that serves EPUB chapters from the engine; PDF/CBZ untouched; selection, navigation and restoration keep working through the retained UI. | Fixture-level rich/JA/bidi/images/tables rendering and selection/navigation/restoration coverage, plus a measured responsiveness and memory check for the slice. Real-corpus, tall-row, font-coverage and retained-heap attribution gates remain open and are named in the slice report. |
| 4+ | Remaining parity: over-tall rows, font admission/fallback coverage, continuous/spread modes, real TOC/sessions, retained-memory attribution, presented-frame measurement, licensed real-book corpus | Per package, with owner acceptance; not authorized by this decision. |

The prototype application shell is not transplanted: `lib/main.dart`,
`lib/fixtures.dart`, `lib/measure_main.dart` and the prototype's own
controller/view stay evaluation artifacts. Only engine and layout code that the
production boundary needs is carried over, adapted to the retained model/message/
effect contracts rather than copied.


### Slice 3 report (EPUB content service behind the retained UI, 2026-09-28)

Implementation, not acceptance: this slice routes content and closes the
gates it names; no package acceptance (5A–5J) is recorded by it, and 5A's
acceptance, the 4/30 accounting and 5B's paused/superseded status are unchanged
(see the [restoration plan](flutter-ui-restoration-plan.md#progress-tracking)).

**What the slice delivers.** A paginated EPUB chapter is served by the Dart
engine behind the retained reader UI:

- `flutter/lib/reader/epub/` carries the layout module (chapter flow, windowed
  layout session, page windows, selection surface, page painting) ported from
  the evaluated prototype and adapted to the reader's typography and palette.
- The controller owns the routing decision, the parsed source, the chapter
  layout session and every completion: a chapter is served by the engine only
  after its canonical stream was compared with the retained Rust stream, and a
  diverging, uncomparable, uncovered-script or oversized chapter stays on the
  retained renderer. No durable offset is ever written from a stream the store
  does not share.
- Page turns are a controller transition over the already-measured window (the
  durable position is the page's canonical start), the window extends in bounded
  batches between frames, and a chapter change, resize, typography change or
  restoration re-paginates through the existing guarded relayout path.
- Continuous mode, PDF and CBZ are untouched; Rust remains the only database
  writer, and the engine's own `@font-face` faces and image resources are
  admitted through controller-injected adapters.

**Known shape of the resident layout.** The chapter session is windowed and
incremental, not eager: the first page is installed from the window around the
requested position, and the remaining top-level nodes are measured in bounded
batches between frames, so the first page does not require laying out the
remainder of the chapter and a page turn is a transition over the
already-measured flow rather than a relayout. The window/batch boundary works
*between* top-level nodes, so a chapter whose single indivisible unit — one
paragraph, list, table or nested container — exceeds the bounded-work ceilings
(512 work units or 32 Ki scalars) is refused by the gate and stays on the
retained renderer instead of being measured in one unbounded call; flattening
composite containers into resumable work items would lift that refusal (open
work). Measurement failure handling is transactional. A window that throws
before adoption releases every painter it created; a forward batch that throws
releases every painter the call created that the adopted prefix does not own,
drops the blocks it appended and restores its node index, cursor and overflow
accounting; a backward batch stages its prepended range aside and commits only
when the batch completes, so a throw leaves the range exactly as it was and
releases the painters the batch created. Construction is covered too: every
painter a context creates is registered, so an interruption *between* a
painter's allocation and its adoption (a standalone paragraph, a table caption,
a table cell paragraph) releases that painter deterministically instead of
leaving it to finalization. Ownership transfers on adoption: a painter the
session already owns is never released by a later failure. Fault-injection tests
reach each path (a throw after a successful earlier prepend, and after
allocating a window/paragraph/caption/cell painter), assert the released set
exactly, and confirm the retry matches a clean layout. This covers *measurement
and construction* failures; a failure inside the collection commit itself (an
allocator failure while a batch's blocks are inserted) is outside it and is not
promised to be atomic. The ceilings are a *structural* admission bound, not a measured
latency guarantee: a table whose cells span many grid positions can still cost
proportional placement work inside one admitted unit (a 64×64 span expansion is
bounded but not small), so a per-cell occupancy bound belongs with the
presented-frame work. The initial window and the admission scans are still
synchronous, and presented-frame timing is not measured (the open gate above). The
measured flow for the visited chapter is retained for the chapter's lifetime
(that is what makes the page turn cheap), so resident memory grows with the
chapter rather than with the page; the prototype's per-line boundary/mapping
work is what keeps each batch bounded. The long-chapter fixture
(`prototypes/epub-dart-eval/fixtures/long-chapter.epub`) is exercised in the
production path, not only in the engine's own tests. Bounding the retained
flow, and attributing it to a real retained-heap measurement, is the open
memory gate above.

**Gates this slice closes.** Fixture-level rich/JA/images/tables rendering and
selection/navigation/restoration coverage through the retained UI, with the
canonical parity audit over the committed corpus (30 books, 52 chapter streams,
byte-identical) and the malformed-`mfrac` engine discrepancy fixed by a
source-derived regression rather than left to the fallback.

**Gates this slice leaves open, named.** Real-book corpus (licensed material not
available in this environment); over-tall table rows; font admission/fallback
coverage beyond the bundled faces (a chapter whose text needs another script
stays on the retained renderer, which preserves the retained host-font
capability until 5C/FM-22 closes it); retained-memory attribution and
presented-frame timing (the slice measures layout work and page sizes, not the
platform's retained heap or presented frames); continuous-mode tiles, spreads,
TOC/session routing and search ownership; and the parity suite's document-area
measurement, which now reads the page box's own repaint boundary (the Dart page
window or the retained raster, whichever painted it) instead of the retained
raster alone: a selection overlay, panel or dialog inside the same rectangle can
no longer supply ink for a blank document, so the assertion's intent — the
document itself painted content — is unchanged and no longer weaker than it.

Slice 3 merged as [PR #141](https://github.com/chaba-dev/shosai/pull/141) at
`b6001998` on 2026-09-30 (`feat(reader): serve paginated EPUB chapters from the
Dart engine`). Merge is delivery, not acceptance: the named gates above stay
open and no package is accepted by it.

### Slice 4 report (EPUB navigation: real table of contents and fragment links, 2026-10-01)

Implementation, not acceptance: this slice routes navigation and closes the
gates it names; no package acceptance (5A–5J) is recorded by it, and 5A's
acceptance, the 4/30 accounting and 5B's paused/superseded status are unchanged
(see the [restoration plan](flutter-ui-restoration-plan.md#progress-tracking)).

**What the slice delivers.** Behind the retained reader UI:

- The Contents panel is served by the book's **real table of contents**. The
  controller resolves the engine's `EpubBook.toc` into durable `(spine, scalar)`
  rows with the retained reference's own rules: a title-only part keeps its
  children at their authored depth but is not a row, an entry whose fragment the
  target chapter does not carry is not a row, and a fragment is decoded once
  before it is looked up. The panel renders those rows with the 4C composition
  (per-level indent, truncation, chapter-number fallback, current entry); the
  current entry is now exactly one row — the last row of the current chapter at
  or before the durable offset — because a real TOC can name one chapter more
  than once and the panel's reveal target is a single key.
- An entry's **fragment offset is published only for a chapter whose canonical
  stream was verified identical to the retained one** (the same comparison the
  content-service slice gates routing on). An entry whose chapter is not
  verified keeps its title and loses its offset, so activating it addresses the
  chapter without a position rather than a scalar the store does not share. A
  structural mismatch between the engine's chapter list and the retained logical
  units (`book.chapters.length != logicalUnitCount`) keeps the whole panel on
  the retained chapter fallback, and a document the engine cannot parse (or a
  non-EPUB document) keeps it too. Qualifying costs one retained-stream
  comparison per distinct chapter a fragment entry names, paid on the panel's
  first open for the chapters the reader has not visited yet and cached for the
  document's lifetime afterwards; the load is bounded by the TOC size, not by
  the page count.
- **Internal links painted on a Dart-rendered page activate** through a typed
  intent (`ReaderLinkActivated`): `#fragment` stays in the current document, any
  other reference resolves against that document's directory, and the target is
  navigated through the existing guarded relayout path with the verified anchor
  offset as the durable position. An unknown or empty fragment navigates
  nowhere; a fragment whose chapter is not verified degrades to the chapter-level
  target; a structural mismatch refuses the link. A press that travels past the
  tap slop is a selection gesture and never activates a link. A newer accepted
  layout, page turn or navigation supersedes a link whose comparison is still
  pending, so an older completion can never move the reader back; a link that
  has no position to go to (a chapter-level row on the chapter already being
  read) targets the chapter start instead of keeping the page while clearing
  the stored position.
- **External links keep the retained restricted policy**: a reference without a
  scheme is internal, `http`/`https`/`mailto` are the only external schemes and
  go to an injected platform opener (no-op when the composition root injects
  none), and every other scheme (`file`, `data`, `javascript`, `custom`, …) is
  refused. The reader never launches a refused scheme and never fetches a book
  resource.
- Engine resolution was aligned with the retained implementation where it
  differed: `resolveEpubReference` now rejects empty segments, a trailing slash,
  encoded separators and encoded dot segments, a query, multiple fragments and
  invalid escapes, decodes the fragment exactly once, rejects control characters
  and validates its base directory; the nav/NCX TOC parse keeps a title-only
  part with its children and reads a title from the link's own text child;
  `resolveInternalLink` returns null for an unknown or empty fragment instead of
  falling back to the chapter start, and an empty or unsafe anchor name never
  becomes an anchor. Anchor offsets were corrected where equal canonical text
  still hid a wrong target: a trailing marker in a heading, an inline block, a
  list item, a blockquote, a table caption, an inline-display container or a
  figure caption now resolves at that block's end rather than its start; a
  collapsed figure records the caption element's own anchor at the caption
  start, and the image's and the image ancestors' anchors at the image start; a
  table row or cell anchor resolves at its own start even when the cell emits
  nothing; a cell's trailing marker follows the production per-block accounting
  (the cell text end for an inline cell, one scalar past it for a cell with
  emitted block children); a caption is collected as the production
  `collect_caption_runs` does (each visible block child is its own run, empty
  runs are discarded with the anchors they recorded, and non-empty runs are
  joined by a generated newline), and a non-collapsed figure leaves its trailing
  markers pending instead of moving them to the figure's start; and a composite
  that the parser does not emit (an empty blockquote, an empty or marker-only
  figure caption or standalone `figcaption`, a table with no caption text and no
  rows, a row with no visible cells, a list item with no text) drops its content
  anchors instead of leaking them onto the next position. Those discards restore
  a snapshot of the pending list rather than truncating by length, because the
  whitespace collapse can re-append a removed span's anchors after a later
  marker. `<nav>` moved from the block-container walk to the production inline
  path (which the canonical comparison did not catch: `<nav><p>A</p><a
  id="x"/></nav><p>After</p>` has the same canonical text in both parsers but a
  trailing marker at 1 there and 2 here). Anchor positions now also follow the
  production raw-to-normalized boundary mapping: when the collapse removes the
  trailing space of the last normal span, an anchor recorded at or after it
  keeps the production offset (one scalar to the right of its collapsed
  position, clamped to the collapsed length, materialized by splitting a span
  when the position falls inside one) instead of sliding left with the
  following preserved-whitespace span; such a mapped end anchor survives span
  merging and joins a later trailing marker instead of being replaced by it,
  and an anchor that was already pending when the walk began keeps its own
  provenance against a descendant duplicate. The production computed-style
  code-block branch is ported too: in the block walker only (never the inline,
  list-item or caption collectors), an element whose computed style is
  monospace plus preserved whitespace is a code block whatever its tag and
  drops its descendants' anchors, while a MathML `math` element and
  whitespace-only content keep their ordinary handling and an inline-only table
  cell keeps the production inline collector's semantics (the conversion never
  applies there). The cascade now derives preservation and the monospace role
  like the retained one: `pre`/`pre-wrap`/`break-spaces` preserve,
  `pre-line`/`normal`/`nowrap` do not, and a `font-family` naming a monospace
  family counts with CSS escapes decoded and `!`-separated `important`
  recognized (a comment is never family text, and a quoted value stops at a raw
  newline in a `style` attribute where the retained stylesheet parser continues
  the line). An inline-only cell now takes the production inline collector for
  its content and anchors (so the block walker's code-block and list-item rules
  do not apply there), and an inline-only cell that mixes an image or MathML
  with an anchor drops that cell's descendant anchors instead of publishing an
  offset it cannot verify. Anchor admission now matches the production rules
  exactly: a name is limited to 1,024 UTF-8 bytes (not UTF-16 units), C1
  controls are refused like C0, and the 4,096-anchor ceiling also bounds the
  unresolved-marker fallback. The shared EPUB source load now owns
  its own bridge cancellation instead of borrowing the requesting panel's or
  relayout's token, so a superseded Contents request (or relayout) can no longer
  cancel a read that a concurrent current one shares; the token is released by
  its own completion and cancelled only when the document is replaced,
  suspended, disposed or released. Every correction is pinned by a test that
  asserts the production parser's own literal offset, and each was
  mutation-checked. The display
  default was aligned while fixing this: the production UA stylesheet assigns a
  display role per tag instead of inheriting it, which the cell's block-child
  decision depends on.

**Gates this slice closes.** Fixture-level TOC and link navigation through the
retained UI: the real TOC panel (EN wide and JA compact renders inspected, no
render defects), same- and cross-chapter fragment navigation (touch tap, primary
mouse click, and drags and long presses that select instead), encoded and
relative references, unknown and empty anchors, structural-mismatch and
unverified or uncomparable-chapter fallbacks, a refused cancellation, a failed
comparison and a failing external opener, supersession by a newer link, page
turn, suspension and document replacement, disposal, cancellation ownership
(each token released exactly once), a Contents request superseded while the
shared source read is still held (the reopened panel keeps the real table of
contents instead of publishing fallback rows), selection still working after
navigation, restoration selecting the matching row (including several rows per
chapter and duplicate offsets), and the restricted external-scheme policy.
Through the **real Rust bridge**, the committed `sample.epub` resolves to the
retained app's own pinned `epub_toc_locations` values, the committed
`links.epub` resolves an encoded cross-chapter fragment to its literal scalar
offset (13) in a chapter whose canonical stream matches the retained one, so the
TOC and link mapping this slice serves is checked against the retained
implementation, not only against the engine's own fixtures.

**Gates this slice leaves open, named.** Real-book corpus (licensed material not
available in this environment); over-tall table rows; font admission/fallback
coverage beyond the bundled faces; retained-memory attribution and
presented-frame timing; continuous-mode tiles and spreads; tabs (5F), progress
ordinals (5G) and search ownership; and engine differences this slice retains
and discloses rather than silently absorbs: the EPUB 3 nav document is
preferred over an NCX where the retained reader tries the NCX first, a nav
entry with an unusable href is skipped individually where the retained parser
discards the whole table of contents, and two canonical-stream differences
found and pinned while verifying the anchor work — `<br/>` emits a newline here
and nothing in the retained collector, and an inline-only table cell keeps its
source's raw whitespace runs there where this port collapses them. Each of the
two makes a chapter that contains it fail the routing comparison and stay on the
retained renderer; they are named in the engine README with the rest of the open
parity work. An inline-only table cell that mixes an image or MathML with an
anchor cannot have that cell's anchors reproduced from the rendered content, so
they are dropped rather than published at an unverifiable offset: a link to such
a name resolves to nothing and a Contents row that targets it is not offered,
which is the reader's established unknown-anchor policy rather than a wrong
target. A name a suppressed walk saw is dropped chapter-wide, including an
occurrence elsewhere in the chapter whose offset this port could verify; the
trade is a missing target rather than a possibly unverifiable one. The platform
opener for allowed external links is an injected adapter;
this slice provides the policy and the seam, not a platform integration, so a
composition root that injects no opener opens nothing.

Slice 4 merged as [PR #142](https://github.com/chaba-dev/shosai/pull/142) at
`4457ac74` on 2026-10-02 (`feat(reader): serve EPUB contents and fragment
navigation from the Dart engine`). Merge is delivery, not acceptance: the named
gates above stay open and no package is accepted by it.

### Slice 5 report (EPUB canonical/TOC parity gaps, 2026-10-02)

Implementation, not acceptance: this slice closes the four named canonical-text
and TOC-source differences left open by slices 3–4; no package acceptance
(5A–5J) is recorded by it, and 5A's acceptance, the 4/30 accounting and 5B's
paused/superseded status are unchanged (see the
[restoration plan](flutter-ui-restoration-plan.md#progress-tracking)). Rust 5B
remains paused reference work, not an implementation path.

**What the slice closes, exactly.**

- **`<br/>` line breaks.** The engine's inline collector emitted a preserved
  newline span for `<br/>` where the retained collector emits nothing. The
  span is gone: production drops `<br/>` entirely, so adjacent runs join
  (`a <em>mid<br/>dle</em> tail` → `a middle tail`), a paragraph whose only
  content is a break is dropped like any empty block, and a trailing marker
  after a break resolves at the paragraph's own text end (`a<br/><a id="x"/>`
  → `x` = 1, not 2). Pinned across paragraphs, `pre`, headings, list items,
  captions, figure captions, and break-adjacent anchors, with the literal
  offsets.
- **Inline-only table-cell whitespace.** The engine parsed an inline-only
  cell's content with the chapter rules and kept source whitespace runs; the
  production cell collector collapses each text run separately (an
  inline-only cell is one collapsed run; a whitespace-only cell contributes
  nothing but keeps its tab separator). Ported the production cell collectors
  (`collect_cell_blocks`/`collect_cell_inline` equivalents) into the
  normalizer, so block/inline classification inside a cell, `li`'s inline UA
  role, nested-table flattening, `pre` preservation, and image alt fallback
  for missing or unresolvable sources now follow the retained stream.
- **Table-cell display-math whitespace.** The same collector port fixes
  `<td><p>before <math display="block">…</math> after</p></td>` to
  `before\n(a)/(b)\nafter\n\n`: each text run around the promoted math
  collapses separately instead of keeping the chapter rules' run spaces.
- **TOC source preference.** The engine preferred an EPUB 3 nav document
  (`properties="nav"`) over the NCX; the retained parser tries the NCX first
  (media type `application/x-dtbncx+xml` alone, no `.ncx` suffix rule) and
  finds a nav document by the manifest id containing "nav" (case-sensitive
  substring), not `properties`. The engine now matches: NCX first, nav second,
  a usable NCX (parseable with `<navMap>`, even with no points) suppressing
  the fallback, an unparseable NCX or one without `<navMap>` falling through,
  the first `<nav>` in document order (no `epub:type` preference) and its
  first descendant `<ol>`.

**How the expectations were derived.** Asymmetric, source-derived: every
canonical-text and anchor expectation above is the retained Rust stream
(`crates/shosai-core/src/epub/render.rs`, `parser.rs`), compared via a
temporary 57-case Rust probe and a 50-case Dart probe over the same
hand-written chapter and TOC inputs (break/inline boundaries, empty and
trailing markers, whitespace-only and inline-only cells, nested blocks and
display math inside cells, cell advancement, and 14 nav/NCX combinations
including different content, invalid and missing sources). The probes were
byte-compared and then removed from both trees before publication; the
production expectations are pinned by the package's own regressions
(`normalize_test.dart`, `address_test.dart`), each carrying the production
literal. Deliberately *not* blessed: the three cases where the retained
collector publishes anchor offsets a suppressed cell walk cannot support
remain the documented suppression residual below, and no Rust file changed.

**Review rounds.** The authorized review found code defects in the first two
diffs; each is fixed with a regression whose literal was re-derived from a
temporary Rust probe (8 trailing-anchor cases, then 1 hidden-name case) before
the probes were removed:

- A cell's trailing marker published at the flattened content end where the
  retained parser publishes it at the anchor walk's own end (a list inside a
  cell renders `a\nb\n\n` on the walk but `ab` in content, so the marker
  moves 3→5; a composed paragraph/display-math/list cell moves 6→7). The
  markers now ride the same first-wins walk map as every other cell anchor,
  and the `EpubTableCell.endAnchorIds` field is gone.
- A limit-error catch around the cell walk silently dropped the walk's
  first-occurrence anchors and let a later duplicate republish; the
  `EpubLimitError` now propagates like the main builder's ceiling.
- The new cell collectors recursed without a depth bound; both now stop
  contributing past the same 64-element ceiling the chapter walkers and the
  anchor walk use.
- The block walk lacked the production `is_math` namespace guard, so an
  un-namespaced `<math>` was parsed as MathML on the walk
  (`[math expression omitted]`) while the content pass rendered its text;
  the walk now falls through to the default inline arm like production.
- The review's second round found that the cell collectors' new depth ceiling
  let a name past the ceiling be republished by a later duplicate at its own
  offset (the routing gate cannot see a textless truncation), where the
  production walkers — which have no ceiling — publish the cell's first
  occurrence. A chapter-wide reservation of the names the walk's map lacked
  was tried first and rejected in the review's third round: it reserved names
  production deliberately never publishes (MathML descendants, code-block
  descendants, anchors of runs that emit nothing), treated any resolved
  occurrence as the first one, and leaked an inner cell's content-pass
  truncation into its parent's walk flag. The accepted fix is the simplest
  safe one: the cell's anchor walk carries a truncation flag set only by the
  anchor walkers (the content collectors are anchor-free), and a truncated
  walk fails admission (`EpubLimitError`, mutation-checked) instead of
  publishing a partial map — the book stays on the retained renderer, whose
  walkers have no such ceiling. Hidden (`display: none`) subtrees stay outside
  the media suppression, like the production walk's own skipping (pinned to
  the retained literal). The reader-level consequence of the rejection is
  pinned end to end as well: the routing suite's admission test opens a book
  whose only difference from a routing control is the fixture's span depth
  (the spans carry no text, so the harness's retained stream is the shallow
  variant's own engine stream), shows the control routed and the over-deep
  book kept on the retained renderer, and fails at its routing assertion if
  the admission throw is removed (the over-deep book then parses, matches the
  gate and routes). No supported-input capability is removed by the rejection: the
  retained renderer is the full-fidelity path for such books, where the
  alternative was routing a stream whose textless anchor divergence the gate
  cannot see.

Every fix is mutation-checked (reverting it fails its regression; the
limit-error regression needed its markup narrowed so only the walk, not the
chapter stream, overruns the ceiling), as is the reader-level admission test
(disabling the throw routes the over-deep book and fails it). The review's
fourth and fifth rounds returned no blockers and signed off on the functional
resolution; two nonblocking cleanups between them — a dangling README
referent and two pieces of dead plumbing (an always-true mode parameter and
an unread table-cell field) — are applied.

**Residuals kept and named (unchanged).** An inline-only cell that mixes an
image or MathML with an anchor drops that cell's descendant anchors (the
retained stream's walk-map offsets cannot be reproduced from the rendered
content; production publishes them, this port suppresses them — pinned per
case). An NCX or nav entry with an unusable href is skipped individually with
a warning where the retained parser abandons that candidate's table of
contents and falls to the next navigation document. The
production manifest is a `HashMap` (arbitrary candidate) where this port takes
the first in manifest order (deterministic superset). Read gate: production
reads a selected NCX (and a nav document it falls back to) through a strict
UTF-8 and lexically-inspectable-XML reader (a tolerant shape walk under
byte/depth/text limits) whose failure fails the book, while structural
mismatches that pass the inspection only fail the candidate's own parse and
fall to the next navigation document; this port decodes TOC bytes with
malformed-UTF-8 replacement, so non-UTF-8 bytes that still yield parseable XML
stay selected silently, and lexically malformed navigation XML opens with a
warning and the nav fallback. Residual visibility differs by class: a
canonical-text divergence in a chapter routes it to the retained renderer;
suppressed media-cell anchors leave the affected links unresolvable and their
Contents rows unoffered; a TOC-source or entry difference changes what the
Contents panel shows — none of them is hidden, and none is a wrong stored
offset for text this port renders.

**Gates this slice closes.** Engine-level canonical parity for the four named
differences: chapters whose only divergence was one of them now compare
byte-identically and route to the Dart renderer. No user-visible routing or
render change beyond that; no package accepted.

**Gates this slice leaves open, named.** All residual gates from slices 3–4:
real-book corpus, over-tall table rows, font admission/fallback coverage,
retained-memory attribution, presented-frame timing, continuous-mode tiles and
spreads, tabs (5F), progress ordinals (5G), search ownership, the media-cell
anchor suppression, per-entry TOC error skipping, the manifest-HashMap
determinism note and the NCX admission difference above.

## Proposed gated work, not an automatic rewrite

Each phase produces a reviewable result. The owner authorizes follow-up work and
chooses adoption separately; no phase changes parity acceptance automatically.

| Phase | Deliverable | Exit / decision gate |
| --- | --- | --- |
| A. PDF reading experience | Both candidates behind the same existing-UI-shaped adapter; continuous and paginated navigation, fit/zoom, selection/copy/search and accessible controls | Inspect licensed real-world PDFs as well as fixtures on unlocked Linux/macOS sessions. Verify long-document behavior, CJK, links, passwords, malformed-input errors and replacement/disposal. Record unsupported cases. Choose pdfrx, pure Dart, or retain Rust. |
| B. SQLite packaged-app spike | Direct sqlite3 worker-isolate service; Drift comparison only if it resolves a concrete tooling need | Offline release apps load SQLite on Linux and macOS without accidental dev-shell paths. Verify transactions, concurrent/stale writes, rollback, close-before-delete, reopen and signing/packaging. Choose dependency and provisioning strategy. |
| C. EPUB vertical slice | One rich chapter through each promising boundary, using existing UI | Demonstrate pagination/continuous flow, images, lists/basic tables, selection across fragments, relayout and stable new-session locations; inspect CJK/bidi and typography. Explicitly list CSS/math limits and compare complexity before choosing a full engine. Delivered as a **standalone full-Dart prototype** ([PR #135](https://github.com/chaba-dev/shosai/pull/135) plus the progressive-layout follow-up in [PR #136](https://github.com/chaba-dev/shosai/pull/136)) that is **not wired into the application**; the hybrid comparison and retained-UI evaluation of the original deliverable remain open, so Phase C is not claimed complete. Prototype evidence is not production acceptance. |
| D. Adoption decision | Scope, architecture amendments, estimated work and accepted limitations | Owner selects language/engine boundaries and retained product requirements. Update architecture/RFD/parity records before production migration. **Recorded 2026-09-28 for EPUB only**: Dart-owned parsing/normalization with Flutter layout; PDF and SQLite remain unselected. |
| E. Incremental implementation | Replace services behind controller-owned adapters, one bounded responsibility at a time | Relevant behavior tests, native checks and visual approvals pass. Remove bridge calls/dependencies only after their final consumers are gone. In progress: the production EPUB engine module and its boundary first, with the production gates above owned per slice. |

A and B can proceed independently when authorized; C did not delay current 4B or
the parity plan. Before A/C, inventory **implemented behavior separately from
future parity requirements**. A reduced prototype is permissible; shipping fewer
capabilities requires a product decision, not a silent omission. E carries that
rule into production: the replacement keeps every retained EPUB capability, and
each slice states which production gates it closes and which remain open.

For A, measure first *displayed content* using a content-aware detector with
bounded waits, validated against captures and native observation. Report cold
and warm trials separately, endpoint definitions, variance, baseline/peak memory,
cache policies and disposal. Pixel diffs are diagnostic; missing text, broken
selection or incorrect navigation fail regardless of a small diff percentage.
Define performance budgets against actual user journeys before accepting a
candidate. Do not use an arbitrary global pixel threshold as the sole gate.

For B/E, prefer one database owner. If temporary Rust/Dart coexistence is chosen,
specify who owns every transaction and cross-table invariant rather than merely
assigning separate tables. Preserve import staging/hash verification and
file/database compensation, deletion-debt recovery, latest-write ordering and
shutdown drains. Use disposable databases for development; no old-data conversion
project is required. A language change alone does not fix lifecycle races.

Across all phases, widgets render immutable state and dispatch typed intent;
controllers own effects, cancellation, resources and revision-guarded completion.
Vendor viewer identity and controller lifetime must survive UI rebuilds. Renderer
pixels, hit testing and selection geometry must refer to the same layout.
Keep library/import/storage separate from document rendering so a PDF engine
decision does not force an unrelated database or EPUB rewrite.

## Decisions still required

- Is eliminating our Rust PDF bridge sufficient, or is a pure-Dart PDF engine
  itself a product/maintenance goal?
- Which real documents and interaction budgets define acceptable experience?
  (For EPUB the direction is fixed; the corpus and budgets still need to be
  named before the responsiveness gate is closed.)
- Should copy/print permissions be enforced, and should the tested getter defect
  be patched locally or reported upstream? Shipping license notices remains
  required regardless of that policy.
- Which Flutter/dependency versions and SQLite/native-asset provisioning path
  will be supported in release packages?
- Which EPUB capabilities are required at adoption? **Boundary decided
  2026-09-28** (Dart parsing/normalization with Flutter layout). Capability scope
  remains governed by the retained reader requirements and the production gates:
  the known prototype gaps — real-world CSS breadth, MathML geometry, WOFF/WOFF2
  and emoji fonts, over-tall table-row splitting, retained-memory attribution,
  presented-frame timing, precautionary continuous-scroll guards and limited
  equivalence fixtures — are open work, not accepted limitations, until the owner
  accepts a reduced scope explicitly.

Provisional preference: validate pdfrx behind the retained UI first, with
dart-pdf as the pure-Dart comparison; use direct sqlite3 as the storage starting
point. These are **evaluation defaults, not selected production dependencies**.

## Evidence and reproducibility

- [Initial document-stack research and corrections](https://ampcode.com/threads/T-01a0dc28-8868-77aa-a669-5fb16002f38c).
- [Linux PDF prototype and consolidated corrections](https://ampcode.com/threads/T-01a0dc39-6b2d-70a1-b491-c1dfcdf05eaa).
- [Independent macOS PDF verification](https://ampcode.com/threads/T-01a0dc79-29a4-7775-a64d-4f3579aa0f79).
- [Dart SQLite investigation and disposable probes](https://ampcode.com/threads/T-01a0dc3a-5504-758f-91e7-a68cfa1a9f73).
- [Dart EPUB evaluation and Phase C prototype](https://ampcode.com/threads/T-01a0e6aa-f4df-7480-a439-cebf039d7623) — merged as [PR #135](https://github.com/chaba-dev/shosai/pull/135) and [PR #136](https://github.com/chaba-dev/shosai/pull/136); the thread's own recommendation was "insufficient evidence", so the adoption is an owner decision above that recommendation, not a result the evaluation proved.
- [EPUB adoption decision thread](https://ampcode.com/threads/T-01a0e675-f4f2-7202-8eef-bdd8ca70b093) — records the owner's `adopt` decision, the delegation rules and the production gates applied to follow-up slices.
- [EPUB navigation slice (real TOC and fragment links)](https://ampcode.com/threads/T-01a0f4ce-cac4-7188-8b8e-7f2ea18745a5) — evidence for slice 4's anchor corrections and the TOC differences it disclosed.
- [EPUB canonical/TOC parity slice](https://ampcode.com/threads/T-01a0fbda-440f-73dc-9bed-5f302161952f) — slice 5's probe comparison and review record for the `<br/>`, inline-only cell, cell display-math and NCX-first TOC closures.

Local PDF evidence is retained under `.amp/in/artifacts/pdf-render-comparison/`,
including `README.md`, `CORRECTIONS.md`, pins/lockfiles, generator, fixture
manifest and canonical-encrypted results. macOS report/crops are alongside it
under `.amp/in/artifacts/macos-*`. These are untracked review artifacts, **not
files guaranteed to exist in a fresh clone**. The threads record remote evidence
locations and archive provenance; old Linux archives predate canonical fixture
corrections. Future runs must pin source and fixture hashes, retain corrections
without overwriting historical evidence, and rerun affected cases on both
platforms rather than extrapolate. No unattended recurring verification is
created by this plan.
