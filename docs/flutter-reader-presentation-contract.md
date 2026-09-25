# Flutter reader presentation contract

Typed presentation model, intent ownership, fixture/live boundary and acceptance
matrix for the reader packages 4B, 4C and 4D of the
[Flutter UI restoration plan](flutter-ui-restoration-plan.md).

- Status: **DRAFT for package 4A review — not accepted; no implementation exists
  under this contract.** Package 4A owns this document; acceptance is recorded in
  the plan, not here.
- Written: 2026-09-25 by package 4A, from the isolated workspace
  `shosai-4a-contract` at remote `main`
  `8e44dd28a6a6b1068f7b8bd16980589f42161fd0` (#126). Local `main`
  (`d1e06f40`, #99) is stale and is not this document's base.
- Governing documents: [restoration plan](flutter-ui-restoration-plan.md)
  (sequencing and acceptance), [reference specification](flutter-ui-reference-spec.md)
  (values, states and `RD-*`/`FM-*` rows), [Flutter architecture](flutter-architecture.md)
  (Elm boundary), [typography](typography.md), [RFD 4](../rfd/0004/README.adoc)
  (frontend/core ownership) and [RFD 6](../rfd/0006/README.adoc) (selection and
  highlighting).
- Reference base: the pinned Iced revision
  `1e54270a6bb24f15630ece336a0575bdbe5be113` (`main@origin` #108) supplies the
  reader composition and values; 1C's 60 captures
  ([evidence](../rfd/0004/evidence/reference-shots-1c/README.md)) are the reader
  reference. Neither establishes Flutter correctness (specification §4.0).

**What this document is not.** It does not add design values, does not restate
the specification's token tables, and does not accept any row. It defines the
typed presentation surface that 4B–4D implement against and the exact point
where fixture-backed presentation stops and 5A/5F/5G live capability begins. No
production code, generated bridge code, l10n catalog, fixture, plan, specification
or RFD is changed by package 4A.

## 1. Purpose, authority and reference state

### 1.1 What this document owns

1. The typed component state and intent surface for reader header, tab strip,
   progress/status bar, edge navigation, Contents, saved places, typography,
   the more panel, search and selection action surfaces (plan package 4A).
2. The widget/controller/effect ownership rules those components obey, including
   the effect-scope key that 5F's tab lifecycle must extend.
3. The fixture-backed versus live capability boundary for 4B–4D versus 5A, 5E,
   5F and 5G, and the list of contracts this document deliberately leaves open.
4. Required disabled/loading/error/empty states, focus/keyboard/semantics/i18n
   behavior, decision-11 tab overflow behavior, and the durable
   navigation/persistence boundary as it constrains presentation.
5. A test and evidence matrix that names the accepting package, the row and the
   fixture for each component behavior.

### 1.2 What this document does not own

| Area | Owner |
| --- | --- |
| Token values, palettes, type sizes, layout metrics, `RD-*`/`FM-*` rows | 1A, [reference specification](flutter-ui-reference-spec.md) |
| Package sequencing, acceptance and counts | [restoration plan](flutter-ui-restoration-plan.md) |
| Elm boundary rules | [Flutter architecture](flutter-architecture.md) |
| Interface and document font roles | [typography](typography.md) |
| Renderer addresses, layout identity, atomic publication, semantic/text mapping, mode/zoom persistence | 5A |
| Durable navigation, TOC resolution, selection geometry and semantic sidecars | 5E |
| Real tab/session lifecycle, shell routing, per-tab saves/effects/resources | 5F |
| Live paginated integration and real progress/page ranges | 5G |
| Pagination measurement and the decision-12 column rule | 5B (calibrates 5A's rule) |
| Selection semantics, anchors, colors and persistence | RFD 6 (preserved, not redefined) |
| Reader default persistence and per-book precedence | 5A/6B (see §9.2) |

The plan's delegation contract applies unchanged: this document does not
authorize interface invention by workers, and an implementer may not waive a
requirement recorded here.

### 1.3 Authorities

This document uses the authority vocabulary of specification §1.1: `Iced`
(pinned revision values and composition), `Retained Flutter` (existing behavior
that must survive), `RFD 6`, `Owner` (a decision recorded in the plan) and
`Plan contract` (a requirement with no Iced reference whose evidence comes from
the later acceptance package).

### 1.4 Reference state and its limits

1. **Iced is cited at the pinned revision.** Line citations such as
   `crates/shosai-app/src/app.rs:5688-5729` are the specification's citations at
   `1e54270a`; the tree at this document's base still contains `crates/shosai-app`
   and the cited reader functions, but the pinned revision remains the reference
   identity (specification §1.3).
2. **1C is merged with unaccepted follow-ups.** PR #119 merged as `950b8a8`;
   the plan still records as unchecked: owner acceptance of FM-21 as a partial
   Iced reference, owner approval of the proposed 1B colour rebaseline, and the
   reproduction/inspection checklist (plan lines 243–248). 1C captures are
   reference-only and cannot accept any 4B–4D row.
3. **1C's production method is recorded and its evidence verifies at this base.**
   The captures were produced by the shared runner through
   `make reference-shots` (manifest `entry_point`/`command`), driven by
   production messages only, with per-capture `reader` facts compared before
   rendering ([reference captures](reference-captures.md), "Package 1C: the
   reader captures"; manifest `capture_code_revision`
   `897eee0911a422fd2501fd23aa8755beface8cfe`, change id
   `nqztxuqyrklvmzqnnrqvzlsntyxkkyvo`, which resolves in this repository's JJ
   history at the 4A base). `sha256sum -c captures.sha256` and
   `sha256sum -c fixtures.sha256` pass in
   `rfd/0004/evidence/reference-shots-1c/` at this base. Verifying the reference
   bytes does not accept the reference's open follow-ups or any row.
4. **The 1C tab capture does not exercise overflow.** `rd-chrome-tabs-w1280-ja`
   opens three books (`Message::OpenLibraryBook` on `slow-rivers.epub`,
   `quiet-cartographer.epub`, `mizu-no-kioku.epub`) and selects tab 0; the
   manifest records `tabs: 3`. RD-04 (overflow, active reveal, keyboard close)
   has **no Iced implementation** and no capture; its authority is owner decision
   11 (manifest `non_iced_authority`).
5. **No Flutter tab or session API exists.** The current Flutter reader is one
   document per `ReaderScreen`; the library shell pushes a single
   `MaterialPageRoute` and restores at most the last active book
   (`flutter/lib/library/view.dart:110-174`). The bridge has no session, tab or
   table-of-contents DTO (`flutter/lib/src/rust/api.dart`; `FlutterDocumentSummary`
   carries only handle, book id, format, title and `logicalUnitCount`). This
   contract therefore defines a presentation-only tab model for 4B and marks
   every real lifecycle/API question as 5F/5A work.
6. **Selection has no Iced reference.** RD-12, FM-16 and FM-17 are RFD 6 plus
   the retained Flutter implementation; 4D preserves them and adds no new
   selection semantics.

## 2. Package and ownership boundary

### 2.1 Package split

| Package | Owns | Must not do |
| --- | --- | --- |
| 4A (this document) | Typed presentation model, intents, ownership rules, states, fixture/live boundary, test matrix | Change code, tokens, catalogs, fixtures, plan/spec/RFDs |
| 4B | Reader header, tab strip, progress/status, edge navigation, panel host/exclusivity, opening/failure chrome; fixture-backed chrome | Define real session lifecycle, bridge session APIs, pagination |
| 4C | Contents/saved-places panel, typography popover, more panel, search bar presentation; bookmark note/delete and Markdown export parity or named exclusion | Invent TOC bridge APIs, settle zoom/typography persistence codecs |
| 4D | Selection action surface and annotation menus, preserving #114 context actions and keyboard equivalents | Change RFD 6 semantics, cross-fragment behavior (5I) |
| 5A | Renderer/persistence contract: addresses, layout identity, DTOs, atomic publication | Widget composition |
| 5E | Durable navigation/TOC resolution, selection geometry and semantic sidecars | Presentation |
| 5F | Real tab/session lifecycle and shell routing; per-tab saves/effects/resources | Presentation composition (4B owns it) |
| 5G | Live paginated integration: real tabs, TOC/link activation, typography, progress, selection and semantic actions | Redefine the presentation contract |

4B–4D may overlap in time only with disjoint write targets. The plan's rule
applies: serialize packages that share `view.dart`, controllers, generated
bridge bindings or fixtures. 4C depends on 4B's panel host; 4D depends on 4C's
panel composition (plan Stage 4 dependency table).

### 2.2 Fixture-backed versus live

| Capability | 4B–4D (fixture-backed) | Live owner |
| --- | --- | --- |
| Document title, format, unit/page count | `FlutterDocumentSummary` from `openDocument`/`openLibraryBook` (existing) | 5G |
| Tab list, selection, close, reveal | Presentation list injected by the test/fixture adapter; no bridge or session API | 5F (lifecycle, duplicate-open, adjacent selection, last-tab return, resource policy) |
| Progress bar and status wording | All RD-05 wording states (`none`/`loading`/`single`/`range`/empty) from supplied presentation data | 5G page ranges; 5A/5B layout identity and pagination |
| Contents entries | Fixture entries plus the EPUB chapter fallback (unit index, chapter number); no TOC DTO exists | 5E durable navigation/TOC resolution |
| Saved places | Existing `listBookmarks`/`toggleBookmark`/`updateBookmarkNote`/`deleteBookmark` (live today) | 5G (integration), 5F (tab scoping) |
| Markdown export | `exportBookmarks` returns the Markdown text (live bridge method, no UI today) | 4C decides delivery target (see §9.2) |
| Typography controls | Reader-local presentation of font size, line spacing, theme and raster zoom; per-book override and persistence mapping deferred | 5A/6B (typed zoom codec, precedence, persistence) |
| Search | Existing `searchDocument` results; presentation only | 5G (live page geometry/highlights) |
| Selection and annotations | Existing controller, surface, overlays and messages (live today) | 5I (cross-fragment, virtualized semantics) |

A fixture-backed component is not completed reader functionality; the plan's
stage exit checklist keeps live paginated integration with 5G.

### 2.3 Effect ownership rules

1. Widgets render immutable model state and dispatch sealed `ReaderMessage`
   values. They never call the bridge, never await an effect, and never mutate
   model or native-resource state (architecture rules 1–2).
2. Message handling computes transitions and starts controller-owned effects.
   Async completions are typed messages carrying the scope key of §3.3 and are
   rejected when stale (architecture rules 3–4).
3. Dialogs, pickers, focus handoff, clipboard and announcements are
   controller-injected adapters (`NoteEditor`, `AnnotationAssociationPicker`,
   `ReaderFocusAdapter`, `SelectionCopier`, `ReaderSelectionAnnouncer`,
   `ReaderFrameScheduler` in `flutter/lib/reader/effects.dart`). 4B–4D add
   `ReaderNavigationAdapter` (leave the reader), `ReaderDocumentPickerAdapter`
   (choose a supported document) and `ReaderTabRevealAdapter` (scroll the strip)
   through the same constructor-injection pattern; a widget that shows a dialog,
   pops a route, opens a picker or starts an automatic reveal itself violates the
   contract.
4. Rust owns document parsing, layout, durable anchors, persistence and
   admission. Flutter owns gestures, overlays, focus, navigation, dialogs and
   responsive composition (architecture rule 6). A presentation component that
   needs durable data requests it with an intent; it never derives a durable
   anchor from pixels or page indices.
5. Opening or closing a panel or the search bar changes the content area and
   therefore must be routed through the layout reporting path
   (`_ReaderLayoutReporter` → `ReaderViewportChanged` → guarded relayout);
   widgets must not resize or re-layout document content themselves. The Iced
   reference invalidates and re-runs layout for every panel toggle
   (`Message::ToggleReaderSettings` etc. in
   `crates/shosai-app/src/app/dispatch.rs:908-925`, `2088-2098`).
   **Known limitation of the current live adapter:** the existing reporter
   (`view.dart:589-618`) reports width, scale, font size and line spacing but not
   viewport height, so a height-only change (search, more, settings) does not
   currently produce a changed report; and it applies the interface `TextScaler`
   to the EPUB book font, contrary to the specification's `T200`/`BF*`
   separation. Stage 4 requirements: (a) fixture-backed viewport-change and
   relayout-intent tests for the width-changing cases, (b) `T200` must leave the
   chosen book font unchanged, with a regression test, and (c) complete
   height/DPR/layout-identity reporting remains 5A/5G work and must not be
   invented here.

## 3. Presentation model and intents

### 3.1 Single source of truth

`ReaderModel` (`flutter/lib/reader/model.dart:73`) remains the only reader state
widgets render. The contract adds presentation state to it as small typed values
and renames the merged tools flag; it does not introduce a second store, a
generic component-state framework, or per-widget mutable state.

Proposed additions (implemented by 4B–4D, listed here as contract shape):

| Symbol | Shape | Purpose |
| --- | --- | --- |
| `ReaderPanel` | `enum { contents, typography, more }` | Mutually exclusive panels (RD-13) |
| `ReaderModel.openPanel` | `ReaderPanel?` | Replaces `toolsVisible`; at most one value |
| `ReaderModel.searchOpen` | `bool` | Search bar is separate from the three panels (RD-11) |
| `ReaderTabPresentation` | `{ String id, String title, bool selected }` | One tab strip entry (fixture-injected in 4B; 5F supplies identity later) |
| `ReaderModel.tabs` | `List<ReaderTabPresentation>` | Ordered tab strip; empty when no tab session |
| `ReaderProgressPresentation` | `{ bool hasDocument, ReaderDisplayUnit displayUnit, ReaderProgressKind kind, int? firstOrdinal, int? lastOrdinal, int percentage }` | Progress bar and status wording inputs (RD-05) |
| `ReaderDisplayUnit` | `enum { chapter, page }` | Which ordinal the status text names |
| `ReaderProgressKind` | `enum { none, loading, single, range }` | Wording state; `none` = no document, `loading` = opening |
| `ReaderSearchPresentation` | `{ String query, bool busy, List<FlutterSearchMatch> results, int currentIndex, String? error }` | Search bar state (RD-11); `query.isEmpty` distinguishes idle from no matches |
| `ReaderContentsEntry` | `{ int depth, String title, int unit, int? offset, bool current }` | Contents row (RD-07); `depth` drives the 12 px indent |
| `ReaderContentsPresentation` | `{ ReaderContentsStatus status, List<ReaderContentsEntry> entries, String? error }` | Contents panel state (RD-07, 4C acceptance) |
| `ReaderContentsStatus` | `enum { loading, ready, empty, failed }` | Contents load state; `failed` carries the error payload |
| `ReaderPageInputPresentation` | `{ String draft, String? error }` | More-panel page input draft and inline validation (RD-10) |
| `ReaderTypographyPresentation` | `{ FlutterBookFormat format, bool continuous, String theme, double epubFontSize, double epubLineSpacing, ReaderRasterFit rasterFit, double rasterZoom }` | Mode-specific controls (RD-09) |
| `ReaderRasterFit` | `enum { fitPage, fitWidth, manual }` | Typed presentation fit; the persisted preference codec is 5A/6B |
| `ReaderExportState` | `enum { idle, busy, failed }` plus an error string | Markdown export feedback (RD-08) |
| `ReaderModalEffect` | `enum { selectionNote, annotationNote, bookmarkNote, associationPicker, documentPicker }` | The one controller-owned modal effect currently active, if any |
| `ReaderModel.modalEffect` | `ReaderModalEffect?` | Gates controls that would start another modal |

Invariants:

- `ReaderModel.tabs` ids are unique; a non-empty list has exactly one `selected`
  entry; an empty list hides the strip; every tab is closable (decision 11), so
  there is no per-tab `closable` flag.
- Progress ordinals are 1-based presentation data supplied to the widget; the
  model's `unit` stays 0-based. Ordinals are never durable addresses and never
  double as a page total (plan contract requirement for 5A–5B).
- At most one `modalEffect` is non-null. The controller sets the slot before
  starting the adapter. Normal completion clears the slot only if the
  completing effect's captured owner scope still owns it; cancellation or
  invalidation (generation change, suspension, disposal) retires the old owner
  and clears its slot in the controller transition itself, not by a discarded
  completion. Later stale completions cannot clear a replacement (architecture
  rule 4). Controls that would open another modal are disabled while the slot is
  set. `busy`/`relayoutBusy` are not modal indicators.

These values are derived in message handling, not in `build`. Widgets may derive
pure display-only values (truncation, label formatting via `AppLocalizations`).

### 3.2 Intents

Existing intents are reused wherever they already express the behavior; new
intents are added only for the restored composition. All are sealed
`ReaderMessage` subclasses in `flutter/lib/reader/message.dart`.

| Intent | Status | Handling owner |
| --- | --- | --- |
| `ReaderOpenRequested(path, {bookId})` | existing (`message.dart:7`) | Controller; unchanged |
| `ReaderUnitRequested(unit, {offset, length})` | existing (`message.dart:26`) | Edge navigation (`unit ± 1`), more-panel page input and search-result navigation — the existing applicable paths. It is not a universal navigation intent: bookmark, annotation and Contents navigation keep their own semantics below |
| `ReaderBookmarkNavigated(unit, {offset})` | existing (`message.dart:39-53`) | Saved places; preserves the existing `replaceReadingOffset: true` behavior that replaces a stale durable offset when a bookmark has none |
| `ReaderAnnotationNavigated(id)` | existing (`message.dart:343`) | Annotation navigation; resolves the annotation in the controller (same-unit selection/focus without relayout, cross-unit navigation) |
| `ReaderBookmarkToggled()` / `ReaderBookmarkNoteRequested([bookmark])` / `ReaderBookmarkDeleted(id)` | existing (`message.dart:39-51`) | Saved places and more panel |
| `ReaderSearchRequested(query)` | existing (`message.dart:34`) | Search bar; controller owns the accepted query |
| `ReaderPanelToggled(ReaderPanel panel)` | **proposed**, replaces `ReaderToolsToggled` | Toggling the open panel closes it; opening one closes the other two; dispatches a layout change |
| `ReaderSearchToggled()` | **proposed**, replaces the search half of `ReaderToolsToggled` | Opening/closing search; closing cancels the in-flight search and clears query/results, mirroring the Iced reference (`dispatch.rs:2269-2285`) |
| `ReaderSearchResultStepRequested({required int delta})` | **proposed** | Moves the current search result by `delta` (±1) without re-querying; ignored when there are no results |
| `ReaderTabActivated(String tabId)` | **proposed**, presentation only in 4B | 4B fixture state; 5F maps it to session activation |
| `ReaderTabCloseRequested(String tabId)` | **proposed**, presentation only in 4B | 4B fixture state; 5F owns close semantics (duplicate-open, adjacent selection, last-tab return, pending saves, resource release) |
| `ReaderLocationNavigated(unit, {offset})` | **proposed** | Contents entry activation. Same handler semantics as `ReaderBookmarkNavigated` (offset replacement); the neutral name keeps TOC navigation from being modeled as a bookmark. TOC-to-durable mapping is 5E |
| `ReaderContentsRequested()` | **proposed** | Contents load and retry; the controller owns the guarded effect |
| `ReaderPageInputChanged(String draft)` / `ReaderPageInputSubmitted()` | **proposed** | More-panel page input draft and submission; the controller validates and converts the 1-based display ordinal to the 0-based unit |
| `ReaderBookmarkExportRequested()` | **proposed** | Controller effect calls `exportBookmarks`; completion carries the Markdown text and an export state |
| `ReaderTypographyChanged({fontSize, lineSpacing, theme, rasterFit, zoom})` | **proposed** | Reader-local presentation change; persistence mapping is 5A/6B (§9.2) |
| `ReaderBackRequested()` | **proposed** | Back action; the controller invokes the injected navigation adapter (leaving the reader is a platform effect, not a widget `Navigator` call) |
| `ReaderOpenBookRequested()` | **proposed** | More-panel "open book"; the controller starts the injected document-picker adapter and opens the selected supported document |
| `ReaderPanelFocusRequested(ReaderPanel panel)` | **proposed** | Focus handoff for keyboard-open panels through `ReaderFocusAdapter`; never a widget-owned `FocusNode` lookup |
| `ReaderSelection*`, `ReaderAnnotation*` | existing (`message.dart:170-354`) | 4D preserves them unchanged |

Tab reveal is **not** a widget intent. The controller starts a reveal effect
through the injected `ReaderTabRevealAdapter` after initial layout, after the
active tab changes, after a close and after a resize; obsolete requests are
ignored by the active-tab identity. Widgets own the Flutter `ScrollController`
that implements the adapter but never initiate reveal themselves.

`ReaderToolsToggled` (`message.dart:59`) and `ReaderModel.toolsVisible` are
retired by 4B; their behavior tests are rewritten against the panel/search
split, not deleted.

### 3.3 Effect scoping

Every asynchronous effect and completion carries a scope key. Until 5F defines
the session type, the key is:

```text
(tab identity, document generation, operation revision)
```

- `tab identity` — the fixture tab id in 4B; the real session/tab identity in
  5F. Effects must not affect another tab, and closing a tab must not release a
  handle still in use (plan §"Session requirements for 5F").
- `document generation` — the existing `ReaderModel.generation`, incremented on
  `ReaderOpenRequested` (`controller.dart:565`); completions with an older
  generation are dropped (`_isCurrent`, `controller.dart:2914`).
- `operation revision` — the existing per-operation revisions
  (`_layoutRevision`, `_selectionRevision`, `_searchRevision`,
  `_bookmarkRevision`, `_annotationRevision`, `_readingStateSaveRevision`,
  `_noteRevision` in `controller.dart:72-101`). A completion whose revision is
  not current must not clear, replace or report an error into newer state.

5F must extend `_isCurrent`/guard helpers with the tab component rather than
adding a parallel mechanism. 4B–4D tests must use completer-controlled effects
to prove stale-completion rejection (architecture "Testing").

### 3.4 Presentation state derivation

- `hasDocument` is `model.document != null`. `kind` precedence: `loading` while
  an open is in flight (the document may be absent or being replaced); `none`
  only when no open is in flight and no document is loaded; otherwise `single`
  or `range` from the presentation data supplied by the fixture (4B) or renderer
  (5G). The status text is present in every case (localized no-book text for
  `none`); the progress bar itself is hidden without a document.
- `displayUnit` is supplied with the ordinals as presentation data, not derived
  from format alone: `page` for paginated EPUB/PDF/CBZ page ordinals, and
  `chapter` only for the EPUB logical-unit fallback. The pinned Iced status bar
  likewise reports page ordinals for paginated EPUB
  (`app.rs:5751-5775`, `single-page-status`/`page-range-status`).
- `firstOrdinal`/`lastOrdinal`/`percentage` are supplied 1-based presentation
  values. 4B fixtures supply them; live production and the mapping from durable
  locations to ordinals are 5A/5G. A widget must not compute progress by
  dividing a page index by a page count, and `logicalUnitCount` must not double
  as a page total (plan contract requirement for 5A–5B).
- `ReaderRasterFit` is a presentation value; the persisted preference codec that
  replaces the `pdfZoom` sentinel remains 5A/6B.
- Mode-specific typography availability is derived from `document.format` and
  `settings.continuous`, never from widget-local booleans.

## 4. Component contracts

Each component below names its reference row(s), state inputs, intents, required
states, interaction/semantics requirements, and the fixture/live split. All
components use the application palette tokens (`ShosaiTokens`) and the reader
palette via `pageColors`; components never introduce literal colors
(specification §3.1–3.3, plan decision 2).

### 4.1 Reader header (RD-01, RD-02)

- Reference: `crates/shosai-app/src/app.rs:5805-5849`; `1C-RD-CHROME`
  (`rd-chrome-w1280-en`, `rd-chrome-c390-ja`, `rd-chrome-b860-*`).
- State inputs: document title (`document.title`, falling back to the localized
  reader title), compactness from `ShosaiTokens.layoutReaderCompactBreakpoint`
  (860 logical px; provisional per P7), `busy`/`relayoutBusy` for action gating.
- Intents: back → `ReaderBackRequested()` (controller invokes the injected
  `ReaderNavigationAdapter`); Contents → `ReaderPanelToggled(contents)`;
  `Aa` → `ReaderPanelToggled(typography)`; `⋯` → `ReaderPanelToggled(more)`.
- Required states: title truncation (wide 58 chars, compact 24 chars; 17 px wide,
  15 px compact) with the full title available to semantics; actions disabled
  when no document is open or while a modal effect is active (`modalEffect`,
  `busy`, `relayoutBusy`).
- Keyboard/focus/semantics: back is a button with an accessible label; the three
  actions are reachable in visual order; Enter/Space activate; focus ring
  visible; the header must not trap Tab.
- Fixture/live: title and format are live from the document summary; tab/session
  identity is not part of the header.
- Tests: `WT` for intents, disabled states, truncation and 200% text; render
  inspection `4B-RENDER` at `W1280`/`C390`, `EN`/`JA`, `T200`.

### 4.2 Tab strip (RD-03, RD-04)

- Reference: `tabs_view` `crates/shosai-app/src/app.rs:5688-5729` (label 12 px,
  truncated at 34 chars, close control `×`, 3 px spacing, [5, 10] padding,
  selected surface+border, horizontal scroll with hidden scrollbar).
  1C capture `rd-chrome-tabs-w1280-ja` (3 tabs, JA).
- State inputs: `model.tabs` (fixture-injected in 4B), `model.openPath`/
  `document.title` for the active tab's title.
- Intents: `ReaderTabActivated(id)`, `ReaderTabCloseRequested(id)`. Reveal is
  not a widget intent: the controller starts the injected
  `ReaderTabRevealAdapter` effect (§3.2).
- Required states:
  - **No tabs**: strip hidden (do not render an empty strip).
  - **Selected**: surface + 1 px border + small radius, distinct from unselected
    tabs (theme token, not a literal).
  - **Overflow (decision 11)**: one horizontally scrollable row; readable tab
    widths with a minimum label width so tabs never shrink indefinitely;
    automatic reveal of the active tab; every tab keyboard-accessible and
    closable; no wrapping into rows; no hidden-tab menu; identical behavior in
    compact windows. The minimum readable width is a value 1A has not frozen
    (§9.2); 4B implements a named constant, records it, and renders both sides of
    it until the owner or a 1A amendment fixes it.
  - **Close affordance**: always present on every tab (Iced reference), with its
    own accessible label naming the tab; a close control is never the only way
    to activate a tab.
- Keyboard/focus: Tab reaches every tab label and every close control in order;
  Enter/Space activate; `Ctrl+W` (platform-adapted) requests closing the active
  tab; `Ctrl+Tab` moves to the next tab; `Ctrl+1..9` selects the Nth tab —
  mirroring the Iced reference (`app.rs:2848-2886`) with platform modifiers.
  After a close, the controller (fixture state in 4B, session policy in 5F)
  determines the new active tab; the strip moves focus to that tab's label and
  the reveal adapter scrolls it fully into view. Keyboard operations on
  initially offscreen tabs must scroll them into view, and a compact resize must
  re-reveal the active tab.
- Fixture/live: **fixture-backed in 4B.** The strip renders whatever tab list the
  presentation state holds; duplicate-open activation, adjacent-tab selection on
  close, final-tab return to the library, removal while open, pending-save
  draining and inactive-tab resource policy are **5F**, and 4B must not encode
  them. Restoration is at most the last active book as one tab (plan decision 6);
  a full open-tab set is not promised anywhere in this contract.
- Tests: `WT` through rendered controls (activation, close, reveal, keyboard,
  200% text) using the `G2` many-tab fixture at `W900` and `C390`; the overflow
  cases must include an initially offscreen **active** tab, keyboard activation
  and closing of an initially offscreen tab, and reveal after a compact resize.
  `4B-RENDER` inspection of the strip at overflow and normal widths, wide and
  compact, `JA`, `T200`. Never accepted on an Iced capture (RD-04).

### 4.3 Progress and status (RD-05)

- Reference: `status_bar` `crates/shosai-app/src/app.rs:5744-5795` (280 px bar,
  11 px status text, single-page vs page-range wording, muted text color).
- State inputs: `ReaderProgressPresentation` (§3.1), progress token
  `layoutReaderProgressWidth`/`layout.progress.girth`.
- Intents: none (read-only). A future scrub action is out of scope for 4B and
  must not be invented.
- Required states (RD-05 assigns all of these to 4B): no document
  (`kind: none`, localized "no book open"); opening (`kind: loading`); single
  location (`kind: single`, ordinal + percentage); page range (`kind: range`,
  first–last + percentage); empty document (percentage `0`, Iced:
  `total_pages == 0 → 0`). The wording names the `displayUnit` kind.
- Semantics: the status text is a live region only when it changes as a result
  of a guarded completion; it must not announce on every rebuild.
- Fixture/live: **4B renders every wording state from supplied presentation
  data** (ordinals and percentage are presentation values, not durable
  addresses). Producing those values from real layout — visible page ranges,
  spreads and the durable-location mapping — is 5A/5G, not a 4B blocker.
- Tests: `WT` for each wording state and empty document; `4B-RENDER` at `W1280`
  and `C390`.

### 4.4 Edge navigation (RD-06)

- Reference: `reader_edge_button` `crates/shosai-app/src/app.rs:5641-5686`
  (glyph 28 compact / 36 wide, fill height, disabled when no page exists).
- State inputs: previous/next availability is supplied presentation data in 4B
  (fixture) and comes from renderer boundaries in 5G. The renderer's real
  boundary semantics (EPUB chapter turn vs raster page, spread boundaries) are
  5A/5G.
- Intents: `ReaderUnitRequested(unit ± 1)`. Disabled buttons dispatch nothing.
- Required states: enabled, disabled, hover/pressed; hidden entirely in
  continuous mode and when no document is open (Iced returns the bare content).
- Keyboard/focus: arrow/PageUp/PageDown and Home/End continue to work through
  the existing shortcuts; the edge buttons themselves are focusable controls
  with accessible labels.
- Fixture/live: fixture-backed availability; real boundaries in 5G.
- Tests: `WT` for enabled/disabled/no-op and keyboard equivalents;
  `4B-RENDER` wide/compact.

### 4.5 Panel host and exclusivity (RD-13)

- Reference: `dispatch.rs:908-925` and `2088-2098`; Iced test
  `reader_header_panels_are_mutually_exclusive` (`app.rs:8517-8540`).
- State inputs: `model.openPanel`, `model.searchOpen`.
- Intents: `ReaderPanelToggled`, `ReaderSearchToggled`.
- Required behavior: at most one of Contents/typography/more is open; opening a
  panel closes the other two; search is independent of the three panels; opening
  or closing any panel or the search bar routes a layout change through the
  reporting path so Rust relayouts against the new content area (width-changing
  cases are testable in Stage 4; height-only reporting is the known 5A/5G gap
  recorded in §2.3 item 5). Panel open/close must preserve the durable reading
  location (the relayout path already carries `unit`/`offset`).
- Focus/semantics: opening a panel moves focus into it through
  `ReaderFocusAdapter`; Escape closes the focused panel and returns focus to the
  header action that opened it. Panel containers expose a label and are
  reachable in order after the header.
- Fixture/live: presentation-only; the panels' real content sources are 4C/5E.
- Tests: `WT` for exclusivity, focus return, Escape, and layout dispatch;
  `4B-RENDER` for each panel state.

### 4.6 Contents (RD-07)

- Reference: `bookmarks_panel` chapter section
  `crates/shosai-app/src/app.rs:6032-6100` (heading/subheading, 12 px entries
  truncated at 38 chars, per-level 12 px indent, chapter fallback numbering);
  1C capture `rd-panel-contents-w1280-ja`.
- State inputs: `ReaderContentsPresentation` (§3.1).
- Intents: `ReaderContentsRequested()` for load/retry;
  `ReaderLocationNavigated(entry.unit, offset: entry.offset)` for entry
  activation.
- Required states: loading (panel opened while entries load), ready, empty
  (document without chapters), failed with the error payload and a retry that
  dispatches `ReaderContentsRequested()`. The current entry is visually distinct
  and scrolled into view when the panel opens.
- Fixture/live: **entries are fixture-provided in 4C.** The bridge exposes no
  TOC DTO; the EPUB chapter-title source exists only inside the core
  (`document.content().chapters`) and is not transferred. The real source is a
  5A/5E deliverable (§9.1). 4C may render the chapter fallback (localized
  chapter number for unit `i`) without inventing titles.
- Tests: `WT` for entry activation, indent/depth, truncation, current-entry
  state, empty/loading/failed; `WT` through rendered controls for 200% text;
  render inspection at `W1280`, `JA`, `T200`.

### 4.7 Saved places (RD-08)

- Reference: `bookmarks_panel` saved-place section
  `crates/shosai-app/src/app.rs:6100-6214`; 1C captures
  `rd-panel-saved-place-w1280-en`, `rd-panel-saved-places-empty-w1280-en`,
  `rd-panel-note-editor-w1280-en`.
- State inputs: existing `model.bookmarks`, `model.bookmarkBusy`,
  `model.toolError`, plus the proposed `ReaderExportState`.
- Intents: existing bookmark intents plus `ReaderBookmarkExportRequested()`.
- Required states: empty (localized empty text, no fabricated rows), list with
  page/chapter label and note, note display, note edit through the
  controller-injected `NoteEditor` adapter, delete, busy (row controls
  disabled), error (row or panel-level message from a guarded completion).
- Markdown export: the bridge method `exportBookmarks(bookId)` returns the
  Markdown text; there is no Flutter UI today and Iced wrote
  `<document>.bookmarks.md` next to the book with only a stderr warning on
  failure. 4C must either implement a named, owner-visible delivery (for
  example clipboard with a success notice, or a save-location adapter) or
  record an explicit named exclusion per the plan's 4C acceptance. Silently
  omitting the action is a scope reduction and is not allowed.
- Tests: `WT` for each state and for export success/failure completion;
  `WT` for note editing through a stub adapter; render inspection at `W1280`,
  `EN`.

### 4.8 Typography (RD-09)

- Reference: `reader_settings_panel` `crates/shosai-app/src/app.rs:5862-5948`
  (EPUB `A−`/`A+` with px label and theme cycle; raster zoom ± with fit
  width/page); 1C captures `rd-panel-typography-epub-w1280-en`,
  `rd-panel-typography-pdf-w1280-en`.
- State inputs: `ReaderTypographyPresentation`.
- Intents: `ReaderTypographyChanged(...)`; theme cycling mirrors the Iced cycle
  light → dark → sepia → light (`theme.rs:38-52`, `117-123`).
- Required states: EPUB mode shows font size (step ±2.0, clamp 8.0–48.0) with a
  numeric label and line spacing; raster mode shows zoom ± and fit width/page;
  controls are disabled while `relayoutBusy`; a failed relayout reports through
  the existing guarded error path, not a widget-local error.
- Fixture/live: the panel changes reader-local presentation in 4B/4C. Persisting
  the change, per-book override precedence and the typed FitPage/FitWidth/Manual
  codec replacing the `pdfZoom` sentinel are **5A/6B** (plan contract
  requirements; §9.1). The current bridge stores only global reader settings and
  a reading-state `zoom`; the library settings screen owns the only existing
  save call (`flutter/lib/library/controller.dart:557`). 4C must not invent a
  per-book persistence schema.
- Tests: `WT` for each control's intents, clamps, mode availability, theme
  cycle and disabled state; render inspection `W1280` `EN`; palette inspection
  belongs to 2C/5G, not here.

### 4.9 More panel (RD-10)

- Reference: `reader_more_panel` `crates/shosai-app/src/app.rs:5966-6030`
  (page input + `of N`, bookmark toggle, open book, search toggle; compact
  stacks vertically); 1C captures `rd-panel-more-w1280-en`,
  `rd-panel-more-c390-en`.
- State inputs: `model.unit`, `ReaderPageInputPresentation`,
  `model.bookmarks` state for the current location, format (page-input and
  search availability), `searchOpen`.
- Intents: `ReaderPageInputChanged(draft)`, `ReaderPageInputSubmitted()`
  (the controller validates the 1-based display ordinal against the document's
  unit count, converts to the 0-based unit, and sets the inline error without
  navigating on invalid input), `ReaderBookmarkToggled()`,
  `ReaderSearchToggled()`, and `ReaderOpenBookRequested()` for "open book".
- Required states: valid input, invalid/out-of-range input (inline error, no
  navigation), busy gating, compact vertical composition.
- Fixture/live: presentation. "Open book" requests the injected
  `ReaderDocumentPickerAdapter` (PDF/EPUB/CBZ); the controller sets
  `modalEffect = documentPicker` before starting the adapter, clears the slot on
  normal completion only if the picker's captured owner scope still owns it, and
  clears it directly in the controller transition when the operation is
  invalidated (generation change, suspension, disposal). The selected document
  is opened through the normal open path, cancellation is neutral, and real tab
  creation/activation policy is 5F. It is not an external-file or
  open-in-place action.
- Tests: `WT` for draft/validation/conversion, invalid input, toggles, compact
  layout and picker selection/cancellation; the package's own inspected renders
  (4C) wide and compact.

### 4.10 Search bar (RD-11)

- Reference: `search_bar` `crates/shosai-app/src/app.rs:6223-6276` (input,
  `n / total`, previous/next, close, wide input capped at 420); 1C captures
  `rd-panel-search-w1280-en`, `rd-panel-search-c390-en`.
- State inputs: `ReaderSearchPresentation` (§3.1) plus `searchOpen`.
- Intents: `ReaderSearchRequested(query)` (existing),
  `ReaderSearchResultStepRequested(delta)`, `ReaderSearchToggled()`, and
  `ReaderUnitRequested(match.unit, offset, length)` for result navigation.
- Required states: idle (no query), searching (busy indicator), results with
  `currentIndex` and `n / total`, no matches (non-empty query, empty results),
  failure through the guarded error path. Close stays enabled while searching:
  closing cancels the in-flight search and clears query/results (Iced reference
  `dispatch.rs:2269-2285`); the controller's `_searchCancellations`/
  `_searchRevision` guard the completion so a cancelled query cannot publish
  results. Previous/next are disabled while `busy` or with no results, and
  stepping wraps or clamps deterministically as recorded by 4C.
- Fixture/live: existing live search over the loaded document; live page
  highlights and geometry remain 5G.
- Tests: `WT` for query submit, result navigation, close-cancel semantics and
  busy/empty/error states; render inspection `W1280`/`C390`.

### 4.11 Opening and failure states (RD-16, RD-17)

- Reference: `crates/shosai-app/src/app.rs:5557-5639`; 1C captures
  `rd-chrome-opening-w900-en`, `rd-chrome-open-error-w900-en`,
  `rd-chrome-missing-file-w900-en`.
- State inputs: `model.contentState` (`loading`/`ready`/`failed`),
  `model.busy`, `model.error`.
- Intents: retry → `ReaderOpenRequested` with the same path/book id; locate →
  controller-injected shell adapter; remove → shell/library removal flow
  (owned by 3D/6A, not by 4B).
- Required states: opening (cover placeholder, title, label), open failure with
  locate/remove actions, missing file alert, content failure inside the
  document view. Errors are live regions and remain visible until resolved
  (plan decision 13).
- Fixture/live: failure states use `G6`-class fixtures (proposed, not created by
  4A); the controller paths already exist.
- Tests: `WT` for each state and action; render inspection `W900`.

### 4.12 Selection actions and annotation menus (RD-12)

- Reference: RFD 6 plus the retained Flutter implementation
  (`flutter/lib/reader/view_selection.dart`, `view_document.dart` annotation
  strip, `view_dialogs.dart` note editor); 1C records these as non-Iced
  authority and has no capture.
- State inputs: existing selection state machine (`ReaderSelectionPhase`:
  idle/selecting/selected/committing), `selectedText`, `anchor`/`focus`,
  `annotations`, `annotationOperations`, `selectionError`, `annotationError`.
- Intents: existing `ReaderSelection*` and `ReaderAnnotation*` messages,
  unchanged.
- Required behavior (4D):
  - Preserve the current selection action surface: Copy (only when the surface
    is copy-eligible), the five RFD 6 colors, Add note, Cancel, keyboard
    equivalents (Enter commits, Escape cancels, Shift+arrows extend, F10/context
    menu opens actions).
  - Preserve the annotation context actions salvaged from #114 (navigate,
    recolor, edit note, delete) with keyboard equivalents, without restoring
    rejected visual ancestors.
  - The action surface is positioned relative to the selected range, stays
    within the viewport, and is reachable and dismissible by keyboard.
  - Overlay painting keeps RFD 6's channel policy (active selection tint,
    search outline/underline, saved highlight fill) — 4D must not change colors
    or precedence.
- Fixture/live: selection and annotation persistence are live today; no
  fixture substitute is required. Cross-fragment selection, tile overlays and
  virtualized semantics are 5I.
- Tests: `WT` through rendered surfaces and shortcuts (pointer press/drag/
  release, keyboard extension, commit, cancel, recolor, note, delete); render
  inspection at `W1280`, `C390`, `T200` and all three reader palettes.

## 5. Cross-component behavior

### 5.1 Disabled, loading, error and empty states

| Component | Disabled | Loading | Error | Empty |
| --- | --- | --- | --- | --- |
| Header | no document; `busy`; `relayoutBusy`; `modalEffect` | `busy` shows the opening state, not a spinner in the header | via `model.error` in the content area | n/a |
| Tab strip | hidden when `tabs` is empty | n/a (presentation list is supplied whole) | n/a (5F owns session errors) | hidden |
| Progress | bar hidden when no document; status text always present | `kind: loading` during opening | n/a | `kind: none` no-book text; percentage `0` for an empty document |
| Edge navigation | no previous/next; continuous mode; no document | n/a | n/a | hidden |
| Contents | rows disabled while loading | `ReaderContentsStatus.loading` | `failed` with error payload and retry | `empty` text |
| Saved places | row actions disabled while `bookmarkBusy`; note editor disabled while a mutation is pending | list-level busy indicator | `toolError` from a guarded completion | empty text, no fabricated rows |
| Typography | controls disabled while `relayoutBusy`; mode-inapplicable controls absent | n/a | guarded relayout error | n/a |
| More | input/actions disabled while `busy`/`relayoutBusy`; picker request disabled while `modalEffect` | n/a | inline page-input error; picker failure through the guarded error path | n/a |
| Search | previous/next disabled while `busy` or with no results; **Close stays enabled** | busy indicator in the input | `toolError` | "no matches" (non-empty query) distinct from idle (empty query) |
| Selection actions | per-button gating (copy vs persistence), unchanged | `committing` state | `selectionActionError`/`annotationError` live region | n/a |

Every error surface is a live region; errors from stale completions must never
appear (architecture rule 4). No component renders a raw bridge error string
without the controller's localization/formatting step.

### 5.2 Focus and keyboard

1. The reader surface keeps first focus for page navigation; chrome controls are
   reachable in visual order after the surface (existing
   `ReaderFocusTarget.surface`/`actions` adapter is extended, not replaced).
2. `Tab`/`Shift+Tab` traverse header → tab strip (labels and close controls) →
   content → panels in order; focus is always visible.
3. Enter/Space activate the focused control; Escape closes the focused panel or
   search and returns focus to the opener; Escape on the surface cancels a
   selection before any navigation.
4. Page navigation: arrow keys/PageUp/PageDown/Home/End (existing
   `CallbackShortcuts` in `view_document.dart:83-95`); Shift+arrows remain
   selection extension (RFD 6) and must not page.
5. Tab shortcuts: `Ctrl+W`, `Ctrl+Tab`, `Ctrl+1..9` mirror the Iced reference
   with platform modifier adaptation; on macOS the command modifier is used.
   These are reader-chrome shortcuts and must not fire while a text field
   (search input, page input, note editor) has focus.
6. Focus is never moved by a widget in response to an effect completion; the
   controller dispatches a focus request through `ReaderFocusAdapter` and the
   completion message is revision-guarded.

### 5.3 Semantics

- Every chrome control has an accessible name; icon-only controls (search,
  `Aa`, `⋯`, edge arrows, tab close) require localized labels.
- The tab strip exposes tabs as selectable items with selected state; close
  controls are separate accessible actions named after their tab.
- The document semantics labels (chapter/page and selectable-text hints) remain
  as they are today (`view_document.dart:99-105`).
- Selection announcements keep using the injected announcer on platforms that
  need explicit announcements (`usesExplicitSelectionAnnouncements`).
- Stable test keys are part of the contract: existing keys
  (`reader-document-semantics`, `reader-content-semantics`, `selection-actions`,
  `reader-tool-error`, `reader-selection-surface`, `reader-page-paint`,
  `reader-focus-indicator`) stay; 4B–4D add keys of the form
  `reader-header-*`, `reader-tab-<id>`, `reader-tab-close-<id>`,
  `reader-progress`, `reader-edge-previous`, `reader-edge-next`,
  `reader-panel-<name>`, `reader-search-*`.

### 5.4 i18n and 200% text

- All chrome text is localized through `AppLocalizations`; the reader currently
  hardcodes English strings, so 4B–4D add reader keys to `app_en.arb` and
  `app_ja.arb` and regenerate/commit the generated localizations (the
  `scripts/check-l10n-codegen.sh` check). Catalog files are a shared write
  target: 4B–4D serialize catalog edits with other packages (plan's disjoint
  write-target rule).
- Status wording uses ICU messages with page/percentage arguments; tab titles
  and book metadata are not translated.
- `T200` (`TextScaler.linear(2)`) must not clip chrome labels, hide close
  controls, break tab activation, or make the header actions unreachable.
  Layout must allow wrapping or truncation per the row's policy, and the
  compact composition must not depend on fixed heights that clip scaled text
  (existing clipping detectors in the 2B harness apply).
- Japanese and mixed-script titles must select a bundled face per
  [typography](typography.md); no system fallback.

### 5.5 Palette and typography

Reader chrome uses the mapped application palette and the reader palettes via
`pageColors`/`shosaiReaderShadTheme` (2C-owned). 4B–4D render light, dark and
sepia reader states for inspection; they do not add colors. Interface text uses
the Inter/Noto Sans JP roles; document text keeps document fonts or the reader
preference (typography.md).

## 6. Durable navigation and persistence boundary

### 6.1 Rust ownership

Rust owns durable anchors, reading state, bookmarks, annotations, reader
settings, search and admission (`crates/shosai-core/src/bridge.rs`). Flutter
presentation never serializes a durable location: no page index, viewport pixel,
scroll offset or layout page count may be stored as a chapter/page identity
(plan contract requirement for 5A–5B).

### 6.2 Existing controller paths

| Concern | Existing path |
| --- | --- |
| Open/restore position | `_openEffect` loads `loadReadingState` (`controller.dart:678`) and applies `unit`/`offset`/`zoom`; failure surfaces as `restorationError`/`toolError` |
| Position saves | `_queueReadingStateSave` (`controller.dart:1505`) coalesces saves and calls `saveReadingState`; `_ReadingStateSaveQueue` keeps at most one pending write and drains in order |
| Drain for navigation | `ReaderController.drainBookWrites(bookId)` (`controller.dart:109`) completes after accepted durable writes and throws `ReaderPersistenceException` with failures |
| Bookmarks/annotations | Guarded completions with `_bookmarkRevision`/`_annotationRevision`; live today |
| Settings | `saveReaderSettings` is called only by the library settings screen (`flutter/lib/library/controller.dart:557`) |

### 6.3 Restoration and sessions

- The shell restores **at most the last active book as one tab** (`_activeBook`
  in `flutter/lib/library/view.dart:110-174`; plan decision 6). This contract
  makes no promise about restoring a full open-tab set; that is deferred.
- Each book keeps its own durable location through reading state; opening a book
  again must restore its position.
- Sessions surviving library navigation, per-tab save draining, and inactive-tab
  resource policy are 5F. Until 5F lands, the single reader route is the only
  session and 4B's tab strip is presentation-only.

### 6.4 Layout-affecting intents

Any intent that changes the content area (panel open/close, search open/close,
compact/wide transition, typography change) must route a layout report so Rust
relayouts and returns guarded results. Widgets must not cache or re-apply
geometry; the existing `_ReaderLayoutReporter` posts the observed layout once
per frame and the controller compares it with the requested layout
(`view.dart:583-624`, `controller.dart:964`). The current reporter's height and
`TextScaler` limitations are recorded in §2.3 item 5: Stage 4 tests the
width-changing cases with fixture-backed expectations, corrects the `T200`/book
font coupling, and leaves full height/DPR/layout-identity reporting to 5A/5G.

## 7. Existing symbols and proposed deltas

### 7.1 Existing symbols this contract builds on

| Symbol | Location | Contract use |
| --- | --- | --- |
| `ReaderModel` | `flutter/lib/reader/model.dart:73` | Single immutable render source; new presentation fields added here |
| `ReaderMessage` sealed hierarchy | `flutter/lib/reader/message.dart:3` | Intent surface; existing messages reused |
| `ReaderController.dispatch` | `flutter/lib/reader/controller.dart:160` | Only entry point for intents; `_isCurrent`/revision guards |
| `ReaderContentState` | `model.dart:303` | Opening/failure states |
| `ReaderSelectionPhase` | `model.dart:301` | RFD 6 selection state machine (unchanged) |
| `ReaderLayout` | `model.dart:37` | Layout identity inputs reported to Rust |
| Effect adapters | `flutter/lib/reader/effects.dart:10-18` | Controller-injected platform effects |
| `FlutterDocumentSummary` | `flutter/lib/src/rust/api.dart:445` | Title/format/unit count |
| `FlutterBookmark`, `FlutterSearchMatch`, `FlutterAnnotation` | `api.dart:332`, `743`, `193` | Panel data |
| `FlutterReaderSettings` | `api.dart:656` | Typography inputs; `pdfZoom` sentinel is 5A/6B work |
| `FlutterSelectionSurface`/`Endpoint` | `api.dart:884`, `810` | Selection geometry |
| Bridge methods | `api.dart:86-159`; `crates/shosai-core/src/bridge.rs` | `openDocument`, `openLibraryBook`, `renderPage`, `selectionSurface`, `searchDocument`, bookmark CRUD + `exportBookmarks`, reading state, reader settings, annotations, `release*` |
| `ShosaiTokens` layout/reader values | `flutter/lib/theme_tokens.dart` | Chrome metrics and palettes; no literals |
| 2B harness detectors | `flutter/test/support/production_shell_harness.dart` | Rendered-control tests and clipping/overflow detection |

### 7.2 Proposed deltas (contract shape; implemented by 4B–4D, not by 4A)

1. `ReaderPanel` enum and `ReaderModel.openPanel` replace `toolsVisible`;
   `ReaderSearchToggled` splits search out of `ReaderToolsToggled`.
2. `ReaderTabPresentation`/`ReaderModel.tabs` with the two tab intents, the
   controller-owned `ReaderTabRevealAdapter` effect, the tab-list invariants and
   an explicit 5F hand-off.
3. `ReaderProgressPresentation`/`ReaderDisplayUnit`/`ReaderProgressKind`,
   `ReaderSearchPresentation`, `ReaderContentsEntry`/`ReaderContentsPresentation`/
   `ReaderContentsStatus`, `ReaderPageInputPresentation`,
   `ReaderTypographyPresentation`/`ReaderRasterFit`, `ReaderExportState` and
   `ReaderModalEffect` derived values.
4. `ReaderBookmarkExportRequested`, `ReaderTypographyChanged`,
   `ReaderPanelFocusRequested`, `ReaderSearchResultStepRequested`,
   `ReaderContentsRequested`, `ReaderPageInputChanged`/`ReaderPageInputSubmitted`,
   `ReaderLocationNavigated`, `ReaderBackRequested` and
   `ReaderOpenBookRequested` intents, plus the `ReaderNavigationAdapter` and
   `ReaderDocumentPickerAdapter` injected effects.
5. Stable semantics keys and localized reader strings (§5.3–5.4).
6. Retirement of `_ReaderControls` (raw path field + Open button) from the
   restored production composition: the 2C approval explicitly excludes that
   panel from approval because stage 4B replaces it, and the Iced reference has
   no path entry. The capability is not dropped — choosing a document moves to
   the more panel's `ReaderOpenBookRequested` picker action and to the library
   entry. A dev/test-only path entry may remain outside the reader chrome but
   must not appear in production renders.

No delta here authorizes a new bridge DTO, a session/tab API, a TOC API, a
per-book settings schema or a pagination API.

## 8. Test and evidence matrix

### 8.1 Fixtures

| Fixture | Status | Use |
| --- | --- | --- |
| `F1` `sample.epub`, `F2` `sample.pdf`, `F3` `sample.cbz` | existing, unverified provenance (spec §5.1–5.2) | basic component states; not capture evidence |
| `G2` many-tab/clipped-label fixture | **proposed, not created** (spec §5.3) | tab overflow, keyboard close of offscreen tabs, clipping |
| `G6` failure-state fixtures | **proposed, not created** | opening/failure chrome |
| `G3` long JA/mixed metadata | **proposed, not created** | truncation at `T200` |
| 1C generated reader tree | existing under `rfd/0004/evidence/reference-shots-1c/fixtures/` | reference comparison only; never acceptance |

4B–4D may build widget-local deterministic fixtures; they must not overwrite the
1B/1C evidence tree or regression fixtures.

### 8.2 Required tests per package

| Package | Behavioral tests (`WT`) | Render inspection | Rows |
| --- | --- | --- | --- |
| 4B | Header intents/disabled states/truncation; panel exclusivity and layout intent; search toggle and close-cancel; progress wording states (none/loading/single/range/empty); edge enabled/disabled/no-op; tab activation/close/reveal/keyboard; many-tab overflow at wide and compact including an initially offscreen active tab, keyboard activation/closing of an offscreen tab and reveal after compact resize (expected: one scrollable row, readable labels, active tab fully visible, no wrap/menu); 200% text; `T200` leaves book font unchanged | `4B-RENDER`: chrome at `W1280`/`C390`, `EN`/`JA`, normal/`T200`, overflow strip, opening/failure states | RD-01, RD-02, RD-03, RD-04, RD-05, RD-06, RD-13, RD-14, RD-16, RD-17 |
| 4C | Contents entry activation/current/empty/loading/failed/retry; saved-place empty/list/note edit/delete/busy/error; export success/failure; typography intents/clamps/mode availability/theme cycle; more page-input draft/validation/conversion and picker selection/cancellation; search submit/step/close-cancel/no-matches | 4C's own inspected renders at `W1280`, `C390` where the row names it, `JA`/`T200` for truncation; no `4B-RENDER` label | RD-07, RD-08, RD-09, RD-10, RD-11 |
| 4D | Selection pointer/keyboard/commit/cancel; annotation navigate/recolor/note/delete; action surface focus and dismissal | 4D's own inspected renders at compact/expanded, `T200`, all three reader palettes, and `D2` sharpness per RD-15 | RD-12, RD-15 |

Cross-cutting: `XA-06` (EN/JA/MIX at normal and 200%) and `XA-07`
(keyboard-only pass) are rechecked by 6C; 4B–4D must not claim them.

### 8.3 Test rules

1. Interaction contracts are tested through the rendered surface (widget tests
   driving gestures/shortcuts), not by dispatching offsets directly to the
   controller (architecture "Testing").
2. Effect staleness is tested with completer-controlled effects: a stale
   completion must not change state, clear newer data, or report an error.
3. Render inspection uses the production shell harness and its geometry
   detectors; generated renders are inspected by the accepting package, not
   merely produced.
4. An Iced 1C capture never substitutes for a Flutter render; RD-04 has no Iced
   capture at all.
5. Widget tests must not assert pixel-perfect toolkit output; they assert
   composition, reachability, states and the contract's semantics keys.

## 9. Explicit deferrals and open questions

### 9.1 Contracts awaiting 5A/5E/5F/5G evidence

| Open contract | Why it cannot be settled here | Owner |
| --- | --- | --- |
| Durable addresses vs ephemeral page indices; progress semantics | Requires 5A addresses/layout identity and 5B measurements | 5A/5B |
| Visible-page ranges, spread state, page metadata for progress/edge navigation | Requires renderer page/tile metadata | 5A/5G |
| TOC extraction and durable navigation targets for Contents | No TOC DTO exists; resolution is a navigation contract | 5A/5E |
| Tab identity, lifecycle, per-tab saves/effects/resources, duplicate-open, adjacent selection, last-tab return, removal while open | Plan requires a frozen lifecycle policy before implementation | 5F |
| Real tabs/TOC/link activation/typography/progress/selection integration | Fixture-backed components are not live functionality | 5G |
| Typed raster zoom codec (FitPage/FitWidth/Manual), legacy sentinel decoding, per-book vs default precedence, continuous-fit semantics | Plan contract requirement; persistence design is not presentation | 5A/6B |
| Per-book typography override persistence | Iced has it (`app.rs:1418-1428`); the Flutter bridge currently stores only global settings and reading-state zoom | 5A/6B |
| Cross-fragment selection, tile overlays, virtualized accessibility | RFD 6 already requires EPUB selection across visual fragments within one spine item and PDF selection within one page; the plan sequences that work into 5I. Virtualized drag-autoscroll and tile overlays are separately deferred | 5I |
| Minimum readable tab width (decision 11) | Owner decision names the behavior, not a value; 1A has not frozen one | 4B (provisional constant, recorded) + owner/1A |

### 9.2 Unresolved product questions (not waived)

1. **Markdown export delivery.** Iced writes `<document>.bookmarks.md` next to
   the book and only warns on failure. The bridge returns the Markdown text.
   4C must choose a Flutter-appropriate delivery (clipboard with notice, save
   adapter, or another explicit behavior) or record a named exclusion; this
   document does not decide it.
2. **Minimum readable tab width.** Decision 11 requires readable widths; the
   numeric floor is unset. 4B must implement and record a named constant and
   render both sides of it until the owner or a 1A amendment fixes the value.
3. **Reader typography persistence path.** Whether the reader's typography panel
   writes global defaults, a per-book override, or both (and with what
   precedence) awaits 5A/6B. Until then the panel must be able to present and
   apply changes locally without inventing a schema.
4. **"Open book" action target in the more panel.** The Iced action opens a
   file picker for a supported document (PDF/EPUB/CBZ) and opens it in the
   application (`Message::OpenFile` → `Message::FileSelected`,
   `dispatch.rs:319-350`); it is not an external-location action. The Flutter
   platform picker is a shell capability injected as a controller adapter;
   selection opens the document through the normal open path, cancellation is
   neutral, and real tab creation/activation is 5F.

### 9.3 1C follow-ups that remain unaccepted

The plan records 1C as merged with these items still unchecked (plan lines
243–248): owner acceptance of FM-21 as a partial Iced reference (Hebrew/Arabic
blank under pinned fonts; RTL composition not preserved); owner approval of the
proposed 1B colour rebaseline replacing the 59 accepted 1B PNGs; and the
reproduction/inspection checklist. 4B–4D may use 1C captures as reference
images; no acceptance claim may rest on them, and the FM-18/colour and FM-21/bidi
limitations remain explicit.

**Preparation is not the approval gate.** 4B depends on approved reader evidence
(plan Stage 4 dependencies: 1C, 2C, 4A). Using the merged 1C images to prepare
and implement does not satisfy the plan's reader-reference acceptance items, and
local Flutter renders never replace that prerequisite. A 4B acceptance record
must state the status of the applicable 1C items (accepted, or explicitly open
with the affected rows named) rather than presenting the reference as approved.

## 10. Review and verification record

### 10.1 Review

| Round | Reviewer | Findings | Disposition |
| --- | --- | --- | --- |
| 1 | Oracle | Six blocking findings and two clarifications: (1) navigation intents routed through `ReaderUnitRequested` would regress bookmark/annotation semantics; (2) "Open book" misdescribed as an external-location action; (3) tab reveal/back bypassed the controller-owned effect path; (4) the existing layout reporter does not report height and couples `T200` to the book font; (5) the typed model omitted search/Contents/page-input/modal/fit state and tab invariants; (6) page-range wording was incorrectly deferred out of 4B; plus the 1C preparation-vs-gate distinction and the cross-fragment selection deferral wording | All fixed: navigation intents separated and `ReaderLocationNavigated` added; `ReaderOpenBookRequested` + `ReaderDocumentPickerAdapter` defined; reveal and back moved to controller-owned adapters; §2.3/§6.4 record the reporter limitations with Stage 4/5A/5G ownership; §3.1/§3.2 add the missing typed values, intents and invariants; RD-05 wording states restored to 4B; §9.3 adds the reader-reference gate; §9.1 corrects the selection deferral |
| 2 | Oracle | Three blocking findings: (1) §2.2/§5.1 still contradicted the corrected RD-05 ownership and no-book status text, and §3.4 left `none`/`loading` precedence undefined; (2) `displayUnit` derived from format alone would label paginated EPUB page ordinals as chapters; (3) `ReaderModalEffect` had no document-picker state and "clear on staleness" could clear a newer modal | All fixed: §2.2/§5.1/§3.4/§4.3/§8.2 aligned and loading precedence defined; `displayUnit` supplied with the ordinals (`page` for paginated EPUB/PDF/CBZ, `chapter` only for the logical-unit fallback); `documentPicker` added with an ownership-checked clear rule |
| 3 | Oracle | One blocking finding: the ownership rule left no transition that releases a modal slot when the operation is invalidated (generation change, suspension, disposal) | Fixed: normal completion requires matching owner scope, while cancellation/invalidation retires the owner and clears the slot in the controller transition; applied to §3.1 and §4.9 |
| 4 | Oracle | None | **No blocking issues remain from any round** |

Every Oracle finding is recorded with its disposition; findings are fixed rather
than waived. Unresolved product questions are listed in §9.2 and are not
presented as accepted scope.

### 10.2 Cross-reference checks performed on this draft

| Check | Method | Result |
| --- | --- | --- |
| Row IDs cited exist | `RD-01…RD-17`, `FM-16/17`, `XA-06/07` compared with specification §4.2 and §4.7 | **PASS** — each cited row exists exactly once in the specification's reader and cross-cutting tables |
| Plan decisions cited exist | decisions 6, 7, 8, 11, 12, 13 and the 5F session requirements read from the plan | **PASS** — decisions and the "Session requirements for 5F" section are present as cited |
| Existing symbols cited exist | `rg` over `flutter/lib/reader/*.dart`, `flutter/lib/src/rust/api.dart`, `crates/shosai-core/src/bridge.rs` | **PASS** — every cited symbol resolves (`ReaderModel`, `ReaderMessage` subclasses, `ReaderController.dispatch`/`drainBookWrites`, effect typedefs, `FlutterDocumentSummary`/`FlutterBookmark`/`FlutterSearchMatch`/`FlutterAnnotation`/`FlutterReaderSettings`/`FlutterSelectionSurface`/`FlutterSelectionEndpoint`, `exportBookmarks`) |
| Line citations match the base tree | targeted `sed`/`rg` on `crates/shosai-app/src/app.rs`, `dispatch.rs`, `flutter/lib/reader/*.dart`, `flutter/lib/library/view.dart`, `api.dart` | **PASS** — corrected two citations during review (`message.dart:39-53`, `app.rs:8517-8540`); all others match |
| 1C reference evidence intact | `sha256sum -c captures.sha256` and `fixtures.sha256` in the 1C evidence directory; JJ lookup of the manifest's capture revision and change id | **PASS** — all 60 capture hashes and the fixture tree verify; `897eee09…` resolves with change id `nqztxuqyrklvmzqnnrqvzlsntyxkkyvo` |
| Markdown links resolve | every relative link target resolved from `docs/` | **PASS** — 13 relative links resolve |
| No production/generator/catalog/fixture changes | `jj diff --stat` on the 4A revision | **PASS** — one file changed: `docs/flutter-reader-presentation-contract.md` (+947) |
| No plan/spec/RFD edits | the same diff lists only this document | **PASS** — no other path appears in the diff |
