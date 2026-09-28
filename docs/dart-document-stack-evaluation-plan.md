# Dart document stack evaluation plan

Status: **proposed, planning only**. This document records the investigations and
decision gates for moving document and database services into Dart. Merging it
does not select a renderer, authorize a production rewrite, or approve baselines.

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

Current [architecture rules](flutter-architecture.md) keep parsing, layout,
anchors and persistence in Rust. They remain in force for production work until
an explicit migration decision updates those rules and the applicable
[RFD 4](../rfd/0004/README.adoc), [RFD 6](../rfd/0006/README.adoc) and restoration
contracts. This document proposes alternatives; it does not silently override
those rules or declare all planned parity capabilities shipped.

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
artifact: it is not wired into the application, it does not amend
[architecture rules](flutter-architecture.md), and **no adoption decision is
recorded here**. Its evidence, reproduction commands, measurements and explicit
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
costs this prototype paid. That follow-up is not authorized by this plan.


## Proposed gated work, not an automatic rewrite

Each phase produces a reviewable result. The owner authorizes follow-up work and
chooses adoption separately; no phase changes parity acceptance automatically.

| Phase | Deliverable | Exit / decision gate |
| --- | --- | --- |
| A. PDF reading experience | Both candidates behind the same existing-UI-shaped adapter; continuous and paginated navigation, fit/zoom, selection/copy/search and accessible controls | Inspect licensed real-world PDFs as well as fixtures on unlocked Linux/macOS sessions. Verify long-document behavior, CJK, links, passwords, malformed-input errors and replacement/disposal. Record unsupported cases. Choose pdfrx, pure Dart, or retain Rust. |
| B. SQLite packaged-app spike | Direct sqlite3 worker-isolate service; Drift comparison only if it resolves a concrete tooling need | Offline release apps load SQLite on Linux and macOS without accidental dev-shell paths. Verify transactions, concurrent/stale writes, rollback, close-before-delete, reopen and signing/packaging. Choose dependency and provisioning strategy. |
| C. EPUB vertical slice | One rich chapter through each promising boundary, using existing UI | Demonstrate pagination/continuous flow, images, lists/basic tables, selection across fragments, relayout and stable new-session locations; inspect CJK/bidi and typography. Explicitly list CSS/math limits and compare complexity before choosing a full engine. |
| D. Adoption decision | Scope, architecture amendments, estimated work and accepted limitations | Owner selects language/engine boundaries and retained product requirements. Update architecture/RFD/parity records before production migration. |
| E. Incremental implementation | Replace services behind controller-owned adapters, one bounded responsibility at a time | Relevant behavior tests, native checks and visual approvals pass. Remove bridge calls/dependencies only after their final consumers are gone. |

A and B can proceed independently when authorized; C need not delay current 4B
or the parity plan. Before A/C, inventory **implemented behavior separately from
future parity requirements**. A reduced prototype is permissible; shipping fewer
capabilities requires a product decision, not a silent omission.

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
- Should copy/print permissions be enforced, and should the tested getter defect
  be patched locally or reported upstream? Shipping license notices remains
  required regardless of that policy.
- Which Flutter/dependency versions and SQLite/native-asset provisioning path
  will be supported in release packages?
- Which EPUB boundary and CSS/format/mode capabilities are required at adoption?

Provisional preference: validate pdfrx behind the retained UI first, with
dart-pdf as the pure-Dart comparison; use direct sqlite3 as the storage starting
point. These are **evaluation defaults, not selected production dependencies**.

## Evidence and reproducibility

- [Initial document-stack research and corrections](https://ampcode.com/threads/T-01a0dc28-8868-77aa-a669-5fb16002f38c).
- [Linux PDF prototype and consolidated corrections](https://ampcode.com/threads/T-01a0dc39-6b2d-70a1-b491-c1dfcdf05eaa).
- [Independent macOS PDF verification](https://ampcode.com/threads/T-01a0dc79-29a4-7775-a64d-4f3579aa0f79).
- [Dart SQLite investigation and disposable probes](https://ampcode.com/threads/T-01a0dc3a-5504-758f-91e7-a68cfa1a9f73).

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
