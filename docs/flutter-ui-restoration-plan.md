# Flutter UI restoration plan

Restore Iced's information hierarchy and reading workflow in Flutter while keeping
useful Flutter capabilities. This is a presentation rebuild and targeted reader
contract work, not a frontend restart or pixel-identical port.

- Opened: 2026-09-14. Restructured: 2026-09-20.
- Status: Stages 1–5 IN PROGRESS; Stage 6 TODO; 4/30 delivery packages fully accepted (1A, 1B, 2A, 5A). 1C and 2B are merged with the follow-ups below still explicit. 4D is implemented and merged in [PR #133](https://github.com/chaba-dev/shosai/pull/133); explicit package acceptance remains pending. 5A was accepted by the owner and merged at [154088a4](https://github.com/chaba-dev/shosai/commit/154088a44ade72ffc77f18c98933f8f3e7c7824e); the 2026-09-28 [EPUB adoption decision](dart-document-stack-evaluation-plan.md#adoption-decision-2026-09-28) supersedes its Rust-specific EPUB portions without erasing that acceptance. 5B is **paused/superseded** by the same decision and is not dispatched. 3D integration acceptance and earlier gaps remain open.
- Governing documents: [RFD 4](../rfd/0004/README.adoc), its
  [implementation checklist](../rfd/0004/IMPLEMENTATION.org),
  [performance contract](../rfd/0004/PHASE-0.adoc), and
  [RFD 6](../rfd/0006/README.adoc) for selection/highlighting.
- Required guidance: [Flutter architecture](flutter-architecture.md) and
  [typography](typography.md).
- Historical context: [original planning thread](https://ampcode.com/threads/T-01a0a37d-11c9-7062-8320-d2229881b01a)
  and [September 14 captures](../rfd/0004/evidence/parity-review-2026-09-14/).

This document owns restoration sequencing and package acceptance. RFD 4 remains
the governing proposal; package 1D records the crosswalk and any contract updates
there. Do not claim the governing records have already been updated.

## Progress tracking

- [x] Restoration direction and retained Flutter capabilities documented.
- [x] Six stages, package dependencies and delegation contract written.
- [ ] Delivery packages accepted: 4/30 (tracked in the stage checklists below).
- [ ] Final restoration exit criteria met and governing records reconciled.

**2026-09-28 handoff:** 2C (#123), 3A (#125), 3B (#126), 4A (#127),
2D (#128), 3C (#129), 4B (#130), 4C (#132) and 4D (#133) are merged. PR #133
merged at [6514f5de](https://github.com/chaba-dev/shosai/commit/6514f5de62caecaf781edee0774bc3880ff95bf5)
on 2026-09-28T04:22:22Z with 15 green CI checks; its publication branch was deleted.
The 4B/4C/4D workspaces were removed and their threads archived after evidence preservation.
Local evidence remains in the default checkout's `target/4b-final-evidence`
and `target/4c-final-evidence` (839/839 files), and `target/4d-final-evidence`
(167 manifest entries verified at closeout, including reproduction scripts and unpublished plan notes).

**Merged presentation closeout:** 4D was implemented and re-verified at revision `05adf79833f6` in the
now-removed `shosai-4d-reader` workspace after the owner's 2026-09-28 light-chrome/document-palette
decision: the shared reader chrome keeps the application palette in every reader theme,
the reader palettes apply to the document area (paper, backdrop and its text leaves),
and the welcome/2B golden passes unchanged. `make test-flutter` 753 passing / 2 skipped,
canonical checks clean, renders/parity/walkthrough byte-identical across two runs
(`.amp/in/artifacts/4d-*`, now preserved in `target/4d-final-evidence`), Oracle clear.
Publication at [629ffeaa](https://github.com/chaba-dev/shosai/commit/629ffeaad7ab)
was content-identical to verified working-copy revision `f991a270`; #133 merged it.
4D still awaits explicit package acceptance; no baseline replacement or approval
was performed. The owner authorized 5A after #133 merged, without waiving 4D,
3D integration acceptance or earlier gaps.

**5A closeout:** the 5A [contract and handoff](flutter-renderer-persistence-contract.md)
and [independent vectors](renderer-contract-fixtures.json) were published in
[PR #134](https://github.com/chaba-dev/shosai/pull/134), from isolated
`shosai-5a-contract`, based on freshly fetched #133, not stale local `main`.
Oracle round 2 closed all blockers. The owner accepted 5A in the
[parent thread](https://ampcode.com/threads/T-01a0e675-f4f2-7202-8eef-bdd8ca70b093),
and #134 merged at
[154088a4](https://github.com/chaba-dev/shosai/commit/154088a44ade72ffc77f18c98933f8f3e7c7824e)
on 2026-09-28T05:17:09Z, making 5A the fourth accepted package. Contract commit
[6b77968b](https://github.com/chaba-dev/shosai/commit/6b77968b2b9f22cac6d6cde826c894f2e38ab31e)
follows the separate closeout/gap commit
[d42596bc](https://github.com/chaba-dev/shosai/commit/d42596bcf20d2d03e915bfc3d7524a4a4f311b05)
(`docs(plan): record restoration gaps and merged presentation closeout`).
Default remains at independent change `uzktlxoq` / `9b23e927` with older on-disk
work deliberately preserved; no baseline was installed. The 2026-09-28 EPUB
adoption decision supersedes the contract's Rust-specific EPUB portions; the
acceptance itself is preserved, not reopened.

**2026-09-28 EPUB adoption handoff:** the owner adopted Dart-owned EPUB
parsing/normalization with Flutter layout, integrated incrementally behind the
retained reader UI ([decision](dart-document-stack-evaluation-plan.md#adoption-decision-2026-09-28)).
This plan keeps owning package acceptance. Recording the decision accepts no new
package: the corrected accounting is 4/30 (1A, 1B, 2A and 5A, accepted before the
decision), and 5B plus every other unchecked item stays unchecked. What the
decision does change here:

- **5B is paused/superseded** as a Rust pagination/bridge-transport package. Its
  contract consumers and measurements are retained as reference evidence; its
  local workspace `shosai-5b-pagination` stays paused and is not resumed. No 5B
  work is dispatched, and its checklist children stay unchecked because the
  package was never delivered — supersession is not acceptance.
- **5A's Rust-ownership statements apply to PDF/CBZ only.** The accepted renderer
  contract is superseded for EPUB by the amended
  [architecture rules](flutter-architecture.md#document-ownership-by-format);
  its durable-location, atomic-publication, bounded-work and persistence rules
  still govern whatever renders EPUB, and Rust remains the only database writer
  while the Dart slice is integrated. Superseding those portions does not reopen
  or reduce the 5A acceptance.
- **5C–5J are not replaced or reassigned.** Their retained reader capabilities
  (rich composition, images/tables/math, navigation/sidecars, sessions,
  paginated and continuous integration, cross-fragment interaction, quality and
  stress) still have to be delivered, now against the adopted EPUB engine. The
  bounded adoption slices below report which production gates they close; they
  do not tick these packages.
- The first implementation slice is the production Dart EPUB engine module and
  its boundary (engine package + tests, no routing change), followed by a
  separate bounded slice that serves EPUB chapter content from it behind the
  retained UI. Both are recorded in the evaluation plan's sequence and are
  reviewed per PR before publication.

**Slice 3 delivery (EPUB content service behind the retained UI, 2026-09-28):**
implementation merged-ready, not acceptance. [#138](https://github.com/chaba-dev/shosai/pull/138)
(the adoption decision and architecture amendments) and
[#139](https://github.com/chaba-dev/shosai/pull/139) (the production Dart EPUB
engine module) merged as `129d9885` and `cac305b1`; the content-service slice
serves paginated EPUB chapters from the engine behind the retained UI, with
PDF/CBZ, continuous mode, the stores and the single Rust database writer
untouched. The controller owns routing, the parsed source and the chapter layout
session: a chapter is served by the engine only after its canonical stream was
compared with the retained Rust stream, and a diverging, uncomparable,
uncovered-script or oversized chapter stays on the retained renderer, so no
durable offset is written from a stream the store does not share. Page turns,
resize/font changes and restoration re-paginate through the existing guarded
relayout path; selection, copy, highlights and reading state keep working
through the retained UI. The slice report, its named open gates (real-book
corpus, over-tall rows, font-coverage beyond the bundled faces,
retained-memory attribution and presented-frame timing) and the parity-suite
document-area measurement change are recorded in the
[evaluation plan](dart-document-stack-evaluation-plan.md#slice-3-report-epub-content-service-behind-the-retained-ui-2026-09-28).
This entry changes no package acceptance: 5A stays accepted, 5B stays
paused/superseded, the accounting stays 4/30, and 5C–5J stay unchecked.

**Outstanding gaps (acceptance remains open; implementation is not approval):**
- **4B/5G**: inherited chrome-height offset (4B
  header/tab/document top 61/48/111 versus reference 52/35/90); 4B acceptance open.
- **4C, 2B, owner**: welcome composition/picker action needs a distinct baseline
  decision. The dark welcome-text golden regression was fixed in #133 and is not
  this composition decision; dark/sepia shared-chrome contrast is also resolved.
- **4C, 2C, owner**: recorded deviations below remain unapproved, including current
  chapter highlight, line spacing, modal note editing, search submission/style/focus,
  compact row heights and text line box. Search token 420 versus reference-rendered
  557 px remains a token-owner discrepancy, not an approved permanent difference.
- **5C/FM-22**: CJK document fallback still missing. **5A/5B/5G/5H**: real page
  boxes, spreads and footer remain absent. **5E/5F/5G**: TOC/tabs/progress still use
  declared presentation fixtures; no live capability acceptance is implied.
- **EPUB adoption gates (owner, 2026-09-28)**: representative real books including
  Japanese and mixed-direction text, images and tables; over-tall table-row
  correctness; font admission/fallback; scroll position and reopen; real frame
  responsiveness and bounded retained-memory verification; and existing reader
  interaction/selection/navigation/restoration coverage with PDF/CBZ untouched.
  Prototype timer gaps are not presented-frame timing and prototype RSS is not
  retained heap; recording the decision closes none of these gates.
- **2A/2B/6C**: remaining native picker/interaction and platform screen-reader,
  keyboard/accessibility matrix coverage stays open where the checklists say so.
- **1C/owner**: reference acceptance/rebaseline approvals remain open; no new
  reference or golden is approved by carrying this closeout forward.
- **3D**: library integration acceptance remains open despite merged 3A–3C delivery.

**Acceptance accounting:** 4/30 is the number of explicitly checked package
acceptances (1A, 1B, 2A, 5A), not the number of merged implementations. The 5A
acceptance is recorded from the owner's acceptance in the parent thread and the
[#134 merge](https://github.com/chaba-dev/shosai/commit/154088a44ade72ffc77f18c98933f8f3e7c7824e);
the 2026-09-28 adoption decision supersedes only its Rust-specific EPUB portions.
Completed delivery/verification children below are checked from their linked
records; merges and scoped baseline approvals do not waive outstanding package
criteria.

**How to update this plan:** each package has a parent acceptance checkbox and
child checkboxes for deliverables, verification and specific decisions. Tick children
as work progresses; tick the parent only when the package's full acceptance criteria
and required approvals are met. A produced deliverable is not an accepted package.
For contract/document packages, verification means review and consistency checks;
for code, it includes executed tests and inspected renders where required.

When starting a package, append `IN PROGRESS — <owner/thread>` to its parent line.
If blocked, use `BLOCKED — <reason; next action>` and retain completed child checks.
On acceptance, replace that status with `DONE — <date; evidence link>`; evidence
must identify the verified revision, checks/results and any required approval.
Record partial test failures beside the unchecked verification item. Reopen affected
checks if later changes invalidate their evidence. Do not mark work done solely
because it exists on another branch or in a historical PR.

Update the stage table's accepted count and status, the overall count above and the
next-package note in the same edit. Use `TODO`, `IN PROGRESS`, `BLOCKED` or `DONE`;
a stage is `DONE` only when all its packages and its exit checklist are checked.
The checked planning items above do not count toward the 30 delivery packages.

**Delegation contract — every package thread owns its checklist.** The thread working
a package updates its checklist throughout the work and at handoff, not only at
completion. Before handoff it checks the completed deliverable and verification
children against revision-pinned evidence (naming the verified revision, the executed
checks and their results), leaves unapproved acceptance and unresolved gaps unchecked
with their owner named, reopens any check whose evidence a later change invalidates,
and updates the stage table's accepted count/status, the overall accepted count and
the current/next-work note in the same edit. When a package is published, merged or
its workspace cleaned up, the responsible thread updates those facts — including
removing obsolete "not published/merged" claims — before closeout. Shared plan edits
are serialized between active threads: one thread owns the file at a time and
announces handoff, so two threads never edit it concurrently.

## Outcome and retained decisions

| Restore from Iced | Preserve or adapt from Flutter |
| --- | --- |
| Warm neutral surfaces, blue accent, type scale and spacing hierarchy | Platform-appropriate dialogs, focus rings and touch targets |
| Library sidebar, constrained header search, header add-books action, continue-reading section, cover-first cards | Compact layouts, large-text support, lazy covers and native import adapters |
| Quiet reader header, document tabs, Contents/saved places, typography controls, bottom progress and edge navigation | Selection/highlighting, annotation actions and last-active-book restoration |
| Rich EPUB content, reading modes and navigation | Controllers, revision guards, cancellation, resource ownership and existing tests |

The following decisions carry forward from the earlier plan:

1. **Match structure and behavior, not pixels.** Use shared tokens and a
   state/behavior checklist backed by captures. Toolkit rendering differences are
   expected. Accessibility must not regress to match Iced.
2. **Iced supplies the design values.** Adopt its accent `#4D5E86`, not #109's
   brown accent. One tracked token source supplies both frontends, including
   application and reader palettes, type scale, radii and gate-relevant layout
   metrics. Respect document fonts separately from interface fonts.
3. **Keep `shadcn_ui` as a behavioral component layer.** Its default appearance
   and layout are not the design specification. Retain Material interoperability
   where needed; map its colors and fonts too.
4. **Keep the Elm boundary; document ownership is format-scoped.** Widgets render
   immutable state and dispatch typed messages. Controller-owned effects report
   guarded completions. Rust owns parsing, layout, durable anchors, persistence
   and admission for PDF and CBZ, and still owns storage, records and search for
   every format. For EPUB the 2026-09-28
   [adoption decision](dart-document-stack-evaluation-plan.md#adoption-decision-2026-09-28)
   moves parsing, normalization, durable anchors, layout and geometry to the
   Dart/Flutter boundary; the behavioral rules below are unchanged.
5. **EPUB pixels and geometry come from one layout.** The retained requirement is
   that hit zones, carets, selection rects and painted text come from the same
   layout and are never reshaped independently. For EPUB that layout is now the
   Flutter layout over the Dart engine; the former "Rust-produced EPUB rasters
   with sidecars" encoding is superseded for EPUB and retained for PDF/CBZ. Font
   quality and performance must be measured, not inferred from library versions.
6. **Multi-tab reading is required; split-document viewing is not.** Sessions
   survive library navigation. Restore per-book durable positions; preserve
   Flutter's restoration of at most the last active book as one tab. Restoring the
   entire open-tab set is deferred.
7. **All six format/mode combinations remain required:** EPUB, PDF and CBZ, each
   paginated and continuous. Paginated-first delivery is an interim milestone, not
   final acceptance. Conditional two-page spreads are required for EPUB, PDF and
   CBZ. Owner confirmed EPUB spreads on 2026-09-20: single-page-first is only an
   implementation sequence; a permanently single-page EPUB reader is not acceptable.
   Use Iced's automatic wide-layout behavior as the initial reference (720 logical
   pixels of available reader width), with the automatic readability fallback in
   decision 12 rather than a width-only rule at larger fonts.
8. **Selection follows RFD 6, not Iced.** Iced has no production interactive
   selection/highlight reference. Preserve Flutter's implementation and align it
   with RFD 6: EPUB ranges stay within one spine item but may cross visual fragments;
   PDF ranges stay within one page. Virtualized drag-autoscroll is deferred.
9. **Library navigation adapts without a drawer.** Owner confirmed on 2026-09-20:
   use a collection sidebar in wide windows and a compact filter row in narrow
   windows. Keep All/EPUB/PDF/CBZ filters and directly accessible Settings in both
   layouts. Start with Iced's 760-logical-pixel breakpoint; verify keyboard access,
   long localized labels and 200% text without clipping or inaccessible controls.
10. **Full import/settings capability is required.** Owner confirmed on 2026-09-20:
    retain staged import discovery, search, selection, cancellation and review,
    language, managed-library location, import behavior and reader defaults.
    These may follow the library/reader milestones but cannot be deferred beyond
    final restoration. Keep native pickers and platform-appropriate controls;
    differences must preserve capability. Any platform limitation requires a new
    explicit owner decision, not an implementer's scope reduction.
11. **Tab overflow uses one horizontally scrollable strip.** Owner confirmed on
    2026-09-20: keep readable tab widths rather than shrinking indefinitely, reveal
    the active tab automatically, and keep every tab keyboard-accessible and
    closable. Use the same behavior in compact windows. Do not wrap into multiple
    rows or replace overflowed tabs with a hidden-tab menu.
12. **EPUB spreads fall back automatically for readability.** Owner confirmed on
    2026-09-20: preserve the chosen reading font size; use one page when two columns
    would be too narrow, and restore two pages when space permits. Never shrink text
    to force a spread. The layout engine owns this choice — for EPUB the
    Dart/Flutter layout, for PDF/CBZ Rust. Package 5A defined the deterministic
    minimum usable column-width rule; the calibration and rendered English/Japanese
    and large-font fixtures that were assigned to the superseded 5B now belong to
    the replacement EPUB slices (or a named later package) and are not claimed by
    this plan; 5H verifies both sides of the boundary and durable-location
    preservation. The numeric threshold remains an engineering measurement, not a
    license to omit two-page support.
13. **Feedback duration follows the required action.** Owner confirmed on
    2026-09-20: successful imports, settings saves and copy actions use brief toasts.
    Failed/partial imports, failed saves, missing files, permission problems and
    cleanup/deletion debt remain visible with details and applicable recovery or
    retry actions. Correctable errors in the current dialog stay inline.
    Cancellation is neutral, not a red error. Do not repeatedly toast the same
    unresolved problem. Package 2D implements and tests this policy; 6A/6B verify
    it in the completed import/settings workflows.

An intentional difference needs an owner-approved entry identifying the behavior,
reason, evidence and acceptance test. Distinguish retained Flutter improvements,
permanent toolkit differences, and temporary gaps with a package owner. Scheduled
work is not an approved permanent difference. The project owner approves product
exclusions and reference evidence; workers cannot waive their own acceptance gates.

## Evidence and PR baseline

The historical screenshots demonstrate the structural mismatch, but are not a
reproducible reference set: they have different sizes and no capture manifest. Some
show the #115 stack tip, while this checkout's Flutter theme uses stock `stone`.
Pin revisions and fixtures before making fresh comparisons.

The EPUB gap is not merely visual styling. `crates/shosai-core/src/bridge.rs` renders
`chapter.search_text()` as uniform text through `selection_surface`; its `unit`
also identifies the durable chapter. Presentation pages, durable locations and
progress must be separated before real pagination can work safely.

PR disposition, updated 2026-09-21: #109–#115 closed with owner approval and
per-PR salvage/supersession comments. Their seven local bookmarks and remote
branches were subsequently deleted with owner approval; use the closed PRs and
their recorded commits as salvage references. #116 was subsequently closed and
its local bookmark/remote branch deleted with owner approval after #118 merged.
The unrelated release PR #9 remains open; closing the stack does not complete any
restoration package.

| PR | Planned treatment |
| --- | --- |
| [#116](https://github.com/chaba-dev/shosai/pull/116) | Closed as superseded by merged #118; crash fix and focus, Enter/Space activation and button semantics repairs delivered and accepted in 2A. Branch deleted with owner approval. |
| [#110](https://github.com/chaba-dev/shosai/pull/110) | Retain `Notice`/`SonnerBridge` infrastructure without pulling in rejected visual ancestors. |
| [#109](https://github.com/chaba-dev/shosai/pull/109), [#113](https://github.com/chaba-dev/shosai/pull/113) | Supersede the accent and library-tab visual direction. |
| [#111](https://github.com/chaba-dev/shosai/pull/111), [#112](https://github.com/chaba-dev/shosai/pull/112) | Salvage feedback behavior selectively; keep actionable failures and persistent debt visible. |
| [#114](https://github.com/chaba-dev/shosai/pull/114) | Retain useful annotation context actions; reassess badges/separators against the restored composition. |
| [#115](https://github.com/chaba-dev/shosai/pull/115) | Adapt documentation to what is actually retained. |

#116 deliberately targets `main` because its bug predates the stack. That is not
itself a stack-integrity failure; reviewing that branch as though it included
#109–#115 was the mistake. Do not impose new stack CI as a restoration prerequisite.

Package 1A records the current remote base and local integration revision using
`.agents/dev jj`. Do not assume local `main` equals `main@origin` or reuse the
September 14 revision without checking. Every task names its exact base and required
predecessors. Recheck PR state before integrating retained changes.

This plan authorizes no push, PR rewrite/closure, merge, deployment or shared-data
write. Prepare and verify locally; obtain explicit approval for external actions.
Remote landing is not a prerequisite for local work on a recorded integration base.

## Stages and dependency rules

Stages are delivery milestones, **not single agent assignments**. Dispatch a
package below, not an entire stage. `TODO` means not completed, not ready to dispatch.

| Stage | Delivery milestone | Packages | Accepted | Status |
| --- | --- | --- | --- | --- |
| 1. Freeze the reference | Pinned base, values, behavior inventory and approved evidence | 1A–1D | 2/4 | IN PROGRESS |
| 2. Safe foundations | Accessible add-books dialog, production-shell harness, theme mappings and retained notices | 2A–2D | 1/4 | IN PROGRESS |
| 3. Library restoration | Iced-shaped library with working existing actions | 3A–3D | 0/4 | IN PROGRESS |
| 4. Reader presentation | Verified reader components and typed presentation contract | 4A–4D | 0/4 | IN PROGRESS |
| 5. Reader capabilities | Real sessions, rich EPUB, navigation, selection and reading modes | 5A–5J | 1/10 | IN PROGRESS |
| 6. Workflow closure | Import/settings coverage and cross-format acceptance | 6A–6D | 0/4 | TODO |

Dependencies are **package IDs**, not whole-stage completion. This permits reference
capture, harness work and contract design to overlap without circular dependencies.

- Start with 1A. It freezes values and a draft inventory before capture or mapping.
- 1B, 1C, 2A, 2B, 4A and 5A can then proceed subject to file ownership;
  2D follows 2A.
- Library presentation requires approved library evidence (1B), harness (2B) and
  mappings (2C), but never waits for the EPUB renderer.
- Reader components require approved reader evidence (1C), harness (2B), mappings
  (2C) and their presentation contract (4A). They can use deterministic fixtures.
- Reader integration waits for real capability packages. Fixture-backed components
  do not count as completed reader functionality.
- 5A is the accepted renderer contract milestone (owner-accepted and merged at
  `154088a4`; its Rust-ownership statements are superseded for EPUB by the
  2026-09-28 adoption decision, while its durability, atomicity, bounded-work
  and persistence rules remain in force). 5B is
  paused/superseded and is not a dispatch target; 5C–5E build rich composition;
  5G integrates the initial paginated reader; 5H–5I deliver continuous/spread
  behavior. 5F supplies real tab/session lifecycle. The adoption decision adds
  bounded EPUB engine slices ahead of 5G; those slices report the production
  gates they close and do not replace any package above.
- No replacement baseline is accepted before 2B. The package changing a surface
  owns its baseline review and names replacement coverage for anything retired.
- Concurrent workers must have disjoint write targets. Serialize packages sharing
  `view.dart`, controllers, generated bridge bindings or fixtures, even when their
  logical dependencies permit parallel work.

## Stage 1 — Freeze the reference

### Delivery checklist

- [x] **1A accepted — base, values and inventory** — owner approved 2026-09-20 — [parent thread](https://ampcode.com/threads/T-01a0bd9e-88c1-746d-941b-d1c5fe258b84). Accepted as the working contract, not as completed UI or capture evidence; 860 px remains provisional and readability calibration stays in 5A/5B.
  - [x] Draft produced: pinned baseline, token specification, fixture inventory and 104 assigned behavior rows. Fixture provenance gaps remain explicit; this is not acceptance.
  - [x] Revisions/fixture identities checked; values and product differences reviewed. Provenance gaps have explicit downstream owners and do not approve affected capture assets.
  - [x] EPUB spread scope decided by owner: required two-page capability; single-page-first delivery allowed, permanent omission rejected. Implementation and visual acceptance remain unchecked in 5H.
  - [x] Compact library navigation decided by owner: wide sidebar, narrow filter row, retained CBZ filter and directly accessible Settings; no narrow-window drawer. Implementation and verification remain owned by 3A.
  - [x] Full import/settings capability scope confirmed by owner; no planned feature exclusions. Delivery and acceptance remain owned by 6A/6B.
  - [x] Tab overflow decided by owner: single horizontal scrolling strip, automatic active-tab reveal, keyboard access and close actions; no wrapping or overflow menu. Implementation and verification remain owned by 4B/5F.
  - [x] EPUB large-font behavior decided by owner: automatic readability fallback to one page, preserve chosen font size, restore two pages when space permits. Contract/calibration belong to 5A/5B; integration acceptance belongs to 5H.
  - [x] Notification policy decided by owner: brief success toasts, persistent actionable failures, inline correctable dialog errors, neutral cancellation and no repeated toasts for unresolved problems. Implementation and verification remain owned by 2D/6A/6B.
  - [Reference specification](flutter-ui-reference-spec.md) produced by [DeepSeek on framework16](https://ampcode.com/threads/T-01a0bdba-4f23-755e-bb41-720410e2859f), corrected through parent review and accepted by the owner as the working contract. Capture-fixture and font follow-ups remain assigned below; acceptance does not certify later implementation rows.
  - [x] Fixture provenance research returned by [DeepSeek on framework16](https://ampcode.com/threads/T-01a0bdd6-6149-73c3-8c23-05289f53b308), recorded in the [fixture README](../crates/shosai-core/tests/fixtures/README.md). Original `sample.*` authoring sources remain unknown; `sample.pdf` also has incorrect xref offsets. Research completion does not approve those assets. Keep regression fixtures unchanged; 1B owns shared deterministic reference-fixture generation for 1B/1C, with per-capture hashes and provenance. Font-toolchain/source records remain with 2C.
  - [x] Baseline verified by parent (2026-09-20): `.agents/dev jj` now works with a system-Nix fallback. Syntax check, JJ status/log and baseline diffs pass; GitHub API confirms remote `main` at [#108](https://github.com/chaba-dev/shosai/commit/1e54270a6bb24f15630ece336a0575bdbe5be113). Pin that revision as the Iced reference and accepted pre-stack base, not stale local `main`. Current application code is [#116](https://github.com/chaba-dev/shosai/commit/f9f64204811b7c475121b8c207b9aea1613ab3da), differing only in the dialog and its test; it still needs 2A's keyboard/semantics repair. Uncommitted additions are planning/evidence plus the wrapper fix, not accepted UI implementation. Future capture-tool changes must record their own revision and this reference base in the manifest.
- [x] **1B accepted — library, import and settings reference** — owner accepted 2026-09-21 in the [verification thread](https://ampcode.com/threads/T-01a0c2a5-aa80-77ef-82c0-64a5eb1024e0), after [PR #117](https://github.com/chaba-dev/shosai/pull/117) merged. Acceptance applies to [merge revision](https://github.com/chaba-dev/shosai/commit/565187cff25efeffe0c228bf443b98ecf57a0bf8), including W900_TALL (900×1200) and W1280_TALL (1280×3250) exceptions. It does not certify Flutter implementation or the non-blocking findings below.
  - [x] Documented reference fixtures generated without overwriting existing regression fixtures; shared generation available for 1C reuse.
  - [x] Capture runner, 59 library/import/settings captures and provenance manifest produced in PR #117.
  - Worker reports 14 Oracle rounds with no outstanding findings, 1197 passing workspace tests, and byte-identical re-render verification. Parent independently confirmed passing GitHub checks at [the PR head](https://github.com/chaba-dev/shosai/commit/b900f911b908a745feb651a516854aff3de29ebd), verified 59 capture and 58 fixture file hashes, and inspected wide Japanese library, compact English library and Japanese import-review captures. The independent verification below supplied the remaining review basis for owner acceptance.
  - [x] Host resource blocker resolved (parent verified 2026-09-21): 2.7 TB available; Cargo registry cache is a real directory with 523 archives, no longer a volatile symlink. Worker reports owner-approved restoration and removal of its isolated build symlink. Earlier unapproved shared-cache deletions remain disclosed; restoration does not erase that incident.
  - [x] Independent reproduction verified by [DeepSeek acceptance thread](https://ampcode.com/threads/T-01a0c2a5-aa80-77ef-82c0-64a5eb1024e0) on the exact #117 merge: two byte-identical 59-capture runs, 86 harness tests passing, negative controls rejecting corrupted evidence/unpinned environment, and unchanged working-tree inventory. All 59 states reported inspected; owner acceptance recorded above.
  - [ ] Non-blocking follow-ups accepted as deferred by the owner: F1 duplicate-selected-file labels and F2 post-import book visibility → 6A; F3 eight-card first-load skeleton → 3C; F4 reference-only mapping and F5 invalid JJ lookup command → 1C shared evidence documentation; F6 absolute output path → document permitted run metadata in 1C; F7 nonzero managed-library move summary → 6B; F8 avoid copying Iced placeholder clipping → 3A/3C. Deferred findings are not evidence of those states. No competing 1B follow-up PR is running.
  - [x] Library/import/settings reference checklist approved by owner on the disclosed basis: two consecutive `make reference-shots VERIFY=1` passes, 86 passing harness tests, unchanged 519-file tree, manifest/checksum/provenance checks and all 59 states inspected. Reported limitations and tall-viewport exceptions remain explicit.
- [ ] **1C accepted — reader reference** — MERGED, REFERENCE DISPOSITIONS RECORDED BELOW — [PR #119](https://github.com/chaba-dev/shosai/pull/119) merged as [950b8a8](https://github.com/chaba-dev/shosai/commit/950b8a8e836b9966480cfa7408b34e82c5e29a21) on 2026-09-22; [DeepSeek implementation](https://ampcode.com/threads/T-01a0c2bf-b12e-7578-9bd6-40491e118496) archived. Worker reports two follow-up Oracle rounds ending clean, after five initial rounds. Merge is recorded separately from the explicit reference acceptance items below.
  - [x] 60 reader captures delivered, including new rich fixtures, document image colours, manual PDF/CBZ zoom, CBZ fit-width and hover. Worker reports two byte-identical reproduction runs and 408 app tests passing (110 harness tests). Follow-up leaves the proposed colour-corrected 1B evidence unchanged, not the older accepted #117 baseline.
  - [ ] Owner accepts FM-21 as a partial Iced reference: pinned fonts leave Hebrew/Arabic blank and Iced list composition does not preserve authored RTL direction. Parent inspected the mixed-script original and confirmed these are limitations, not successful shaping evidence. Full Flutter/Rust behavior remains required in 5C. FM-18 demonstrates document image colours only; CSS text-colour support remains with 5G. Other recorded Iced defects (block-anchor href loss, inline images/fallbacks) are not restoration targets.
  - [ ] Owner approves proposed 1B colour rebaseline: PR #119 corrects BGRA/RGBA encoding and replaces all 59 previously accepted 1B PNGs. Existing 1B acceptance remains tied to #117 until explicitly superseded. Parent inspected corrected library and odd-final EPUB originals; this is not rebaseline approval.
  - Parent inspected the new marks capture: list, quote, styled link and coloured image are visible. Reproduction is against the proposed corrected baselines, not the previously accepted 1B PNG bytes.
  - [ ] Reproduction checked; evidence inspected and reader checklist approved.
- [ ] **1D accepted — governing records**
  - [ ] RFD/checklist/performance crosswalk and applicable boundary documentation updated.
  - [ ] Records checked against frozen contracts and retained implementation.

| ID | Scope and ownership | Depends on | Required result |
| --- | --- | --- | --- |
| 1A | Maintainer: base, token specification, fixtures and behavior inventory | — | Pin revisions, font/fixture identities, exact client sizes, DPR, text scales, palettes and states. Inventory existing format/filter behavior, including CBZ. Assign every row an authority and accepting package. Freeze values and define allowed differences. |
| 1B | Iced library, import and settings reference capture tooling and evidence | 1A | Deterministic library captures for expanded/compact, search/filter, continue-reading, loading/empty/error and long multilingual metadata states, plus `1B-IMPORT` and `1B-SETTINGS` reference states assigned by the specification; owner-approved checklist. Flutter implementation and acceptance stay in 6A/6B. |
| 1C | Iced reader reference capture tooling and evidence | 1A | Reader chrome/panels and format × mode evidence with manifest; owner-approved checklist. Use RFD 6 tests and Flutter evidence for selection, not impossible Iced captures. |
| 1D | Governing-document crosswalk | 1B, 1C, 4A, 5A | Update RFD 4/checklist/performance contract to the retained decisions and package owners. Distinguish M3.1's functional completion from the still-open visual gate. Adapt #115 only to implemented behavior. |

Use an explicit capture entry point, such as `make reference-shots`, with software
rendering under Xvfb where appropriate. Record commands, revision, fixture hash,
fonts, client dimensions, screenshot dimensions and DPR. The performance navigation
runner is not a screenshot harness. Share capture infrastructure between 1B and 1C
under one owner rather than building competing runners.

### Stage exit checklist

- [ ] Every acceptance row has a testable behavior, authority, configuration,
  evidence where applicable, approver and accepting package.
- [ ] Unsupported Iced states are marked not applicable, not fabricated or omitted.
- [ ] All four packages accepted with evidence linked above.

## Stage 2 — Establish safe foundations

### Delivery checklist

- [x] **2A accepted — add-books repair** — owner accepted 2026-09-21; [PR #118](https://github.com/chaba-dev/shosai/pull/118) merged as [46cf21e](https://github.com/chaba-dev/shosai/commit/46cf21e7903b10bb6e5df20a2ae80aebef82b3b9). [DeepSeek implementation](https://ampcode.com/threads/T-01a0c2c0-52e7-729b-8f71-ba87a82ea1bd) incorporates #116 plus accessibility repairs. #116 is closed as superseded and its branch deleted with owner approval.
  - [x] Layout fix and accessible activation behavior implemented in the two owned dialog/test files. Oracle round 1 raised three test-strength findings; round 2 confirmed all resolved with no outstanding issues.
  - [x] Both choices verified with pointer, focus, Enter/Space and active semantics. Parent independently reran all 14 targeted tests (passing), confirmed all 15 CI checks pass, and inspected both focus-ring renders with no clipping or displacement. Worker reports 295 full-suite tests passing and no unfocused visual change versus #116. Native screen-reader and native-picker smoke remain untested here; 2B owns platform smoke coverage.
- [ ] **2B accepted — verification harness** — IN PROGRESS — merged; native dismissal/recovery subsequently verified in #125, full package acceptance not recorded. [PR #120](https://github.com/chaba-dev/shosai/pull/120) merged as [0dde645](https://github.com/chaba-dev/shosai/commit/0dde6455b7beb16d86e8b0d7daee4224e2514f3b) on 2026-09-22. [Linux implementation/validation](https://ampcode.com/threads/T-01a0c335-958f-7254-a60e-f8e17960a06a) and [macOS fixes/verification](https://ampcode.com/threads/T-01a0c5f1-a66a-70bc-a689-66c6c65c8d09) threads archived after publication and verification.
  - [x] Production-shell golden harness, bounded Linux native smoke runner and window-scoped macOS capture path implemented. Final published revision [01623b6](https://github.com/chaba-dev/shosai/commit/01623b69a9f9030baf421e846d1528854c159617) verified on both platforms: 69 visual tests each; Linux 370 full-suite passes, macOS 368 passes and two Linux-only skips; zero clipping findings; all 12 renders byte-identical across repeated runs. Linux X11 picker dismissal/recovery passes. Oracle fixes and follow-up reviews closed; no detector tolerance widening or hidden skips.
  - [x] Owner approved nine new macOS baselines and six updated Linux baselines for the typography and scaled-button clipping fixes on 2026-09-22. All 15 installed images hash-match the approved candidates. This approves current rendering, not Iced layout parity or the known overlap below.
  - [x] Native macOS dismissal, recovery and window-scoped screenshots verified on the frozen #125 head, as recorded in [its native smoke evidence](https://github.com/chaba-dev/shosai/pull/125): unlocked console, successful preflights, native panel open, Escape dismissal, recovery true and runner PASS. This supersedes the earlier Automation-permission blocker; it does not prove file selection/confirmation or native behavior of subsequent reader packages.
  - Deferred production defect: at 900×700 with 200% Japanese text, the floating Add books button overlaps the bottom-right card metadata. Stage 3 owns the layout fix; geometric clipping detectors do not claim to detect arbitrary overlap.
- [ ] **2C accepted — theme mappings** — IN PROGRESS — implementation merged in [PR #123](https://github.com/chaba-dev/shosai/pull/123); scoped theme baseline approvals recorded there, not blanket Iced parity. Reader chrome palette mapping was corrected under the owner decision recorded in 4D; that correction is verified and merged in #133.
  - [x] Shared tokens and Rust/Shad/Material mappings implemented in #123.
  - [x] Mapping/literal checks pass; palette renders inspected and baselines reviewed at #123: 13 Linux and nine macOS approved images installed byte-exact, Linux 394 passes, macOS 392 passes / two skips, all 15 CI checks green. This historical verification does not certify the 4D chrome/document-palette correction; that correction is verified in 4D.
- [ ] **2D accepted — notices** — IN PROGRESS — implementation and library integration merged in [PR #128](https://github.com/chaba-dev/shosai/pull/128); explicit package acceptance remains unrecorded.
  - [x] Retained notice infrastructure and persistent/transient feedback policy implemented.
  - [x] Exactly-once notice tests pass; actionable failures remain visible. #128 records 197 notice/library tests, full suite 608 passes / two skips / zero failures, inspected EN/JA/T200 renders and Oracle closure.
  - [x] Decision 13 tested: success toast expiry, persistent failure details/recovery, inline dialog errors, neutral cancellation and suppression of duplicate unresolved notices. Library failures/debt remain inline without duplicate notices; reader integration is separately owned.

| ID | Scope and ownership | Depends on | Required result |
| --- | --- | --- | --- |
| 2A | `library/view_dialogs.dart` and dialog tests: repair #116 | 1A | Both import choices lay out under active semantics, receive focus and activate with Enter/Space and pointer input. Exercise real dialog builders, stubbing only the platform boundary. |
| 2B | Flutter test harness and bounded desktop smoke runner | 1A | Production shell including `ShadAppBuilder`; deterministic fonts/data/rasters. Detect overflow and the known clipped-label fixture separately. Native picker smoke coverage and failure screenshots. |
| 2C | Shared tokens, Rust theme mapping, `app_theme.dart`, paint palettes | 1A, 2B | Map Shad and retained Material colors/type/radii plus Rust consumers. Assert mappings on both sides and reject new literal theme colors. Inspect rendered light/dark/sepia states; review changed baselines. |
| 2D | Notice infrastructure and feedback policy | 1A, 2A | Transplant #110 without rejected ancestors; implement decision 13 and test exactly-once notices. Reuse #111/#112 selectively only where their behavior matches the approved policy. |

### Stage exit checklist

- [ ] Known dialog and clipping regressions fail the new checks.
- [ ] Production-shell baselines reviewed; shared values mapped, not approximated.
- [ ] All four packages accepted with evidence linked above.

## Stage 3 — Restore the library

Primary ownership: `flutter/lib/library/view*.dart` and targeted library tests.
Preserve controllers and adapters unless a named behavior needs a small extension.

### Delivery checklist

- [ ] **3A accepted — library navigation** — IN PROGRESS — implementation merged in [PR #125](https://github.com/chaba-dev/shosai/pull/125); disclosed differences and package acceptance remain distinct from delivery.
  - [x] Header, wide sidebar and narrow filter row implemented; All/EPUB/PDF/CBZ and Settings accessible without a drawer.
  - [x] Reference states, selected filters, keyboard focus and 200% text verified. #125 records 28 navigation tests and inspected matched C390/EN/JA/T200 captures; its historical golden failures are explicitly recorded, not treated as green. Later library baseline installs are recorded in #126/#129.
- [ ] **3B accepted — cards and grid** — IN PROGRESS — implementation and owner-approved baseline install merged in [PR #126](https://github.com/chaba-dev/shosai/pull/126); retained layout/menu differences remain disclosed there.
  - [x] Cover-first cards and responsive grid implemented with existing actions retained.
  - [x] Missing covers, multilingual metadata, lazy loading, open/removal actions verified. Installed-baseline verification: Linux 497 passes / one skip; macOS 495 passes / three skips; zero failures, repeat renders identical, CI green. Native screenshots were not claimed.
- [ ] **3C accepted — continue-reading and states** — IN PROGRESS — implementation, owner-requested automatic paging and approved baseline install merged in [PR #129](https://github.com/chaba-dev/shosai/pull/129); transition polish was explicitly deferred.
  - [x] Continue-reading, skeleton, empty, filtered-empty and failure/debt states implemented.
  - [x] Correct book/position and each distinct collection state verified. #129 records durable-position checks, discriminating recovery/paging tests, independent macOS evidence and installed-baseline Linux verification (562 passes / two skips / zero failures, repeat artifacts identical). Native interaction is not claimed; 3D integration acceptance remains open.
- [ ] **3D accepted — library integration**
  - [ ] Restored library integrated with import, search, filters, paging and removal.
  - [ ] Shell interaction checks pass; matched captures inspected; remaining gaps assigned.

| ID | Package | Depends on | Acceptance |
| --- | --- | --- | --- |
| 3A | Header, expanded sidebar, compact filters | 1B, 2C | Title/subtitle, constrained search, header add-books action; Settings at sidebar bottom in wide layout and directly accessible in compact layout. Narrow layout uses a filter row, not a drawer. Retain All/EPUB/PDF/CBZ. Start at 760 logical pixels; verify selected state, keyboard focus and 200% text. |
| 3B | Cover-first card and responsive grid | 3A | Cover, title, author, format and progress hierarchy; missing covers and long English/Japanese metadata; lazy loading, open and removal actions preserved. |
| 3C | Continue-reading and collection states | 3B | Continue opens the correct book/position; skeleton, empty library, no matches, load error and cleanup/deletion debt states remain distinguishable. |
| 3D | Library integration and visual acceptance | 3C, 2A, 2D | Search, filtering, paging, import entry and removal work through the shell; matched-state captures inspected. Record import/settings work still owned by Stage 6. |

### Stage exit checklist

- [ ] Library matches the approved composition and existing operations still work.
- [ ] Remaining settings/import workflow work explicitly assigned to Stage 6.
- [ ] All four packages accepted with evidence linked above.

## Stage 4 — Restore reader presentation

Primary ownership: `flutter/lib/reader/view*.dart` and reader component tests.

### Delivery checklist

- [ ] **4A accepted — presentation contract** — IN PROGRESS — draft contract merged in [PR #127](https://github.com/chaba-dev/shosai/pull/127); explicit contract acceptance remains unrecorded.
  - [x] Typed component state/intents and fixture/live boundaries specified in `flutter-reader-presentation-contract.md`.
  - [x] Contract reviewed against Elm ownership and durable-navigation integration needs. #127 records four Oracle rounds with all findings fixed and no final blockers; renderer/session decisions remain assigned downstream.
- [ ] **4B accepted — reader chrome** — IN PROGRESS — implementation and six approved reader baselines merged in [PR #130](https://github.com/chaba-dev/shosai/pull/130). Visual baseline approval does not waive fixture-only tabs/progress, missing native interaction proof or the inherited chrome-height offset recorded under 4C/4D.
  - [x] Header, tab strip, progress and edge-navigation components implemented.
  - [x] Fixture renders inspected; loading/disabled states and keyboard intents tested. Installed-baseline head: Linux 666 passes / two skips; macOS repeat 664 passes / four skips / zero failures (first run hit the disclosed teardown race); all 15 CI checks green, nine macOS goldens zero drift and repeat renders identical. Evidence retained in `target/4b-final-evidence` in the default checkout.
  - [x] Many-tab overflow tested at wide/compact widths: one scrollable row, readable labels, active-tab reveal and keyboard activation/closing of initially offscreen tabs. C390/T200 long labels, fractional 1.92 and nonlinear scaling verified on Linux/macOS with pre-fix mutation discrimination.
- [ ] **4C accepted — panels and typography** — IN PROGRESS — implementation merged in [PR #132](https://github.com/chaba-dev/shosai/pull/132) as [e5d0be70](https://github.com/chaba-dev/shosai/commit/e5d0be70b1ee0c3bc8ea47fbb2a3ff82fedd51cf); [implementation thread](https://ampcode.com/threads/T-01a0e422-e7df-759b-9d47-44dfc146c78b) archived and isolated workspace removed. Evidence preserved in the default checkout's `target/4c-final-evidence` (839 files hash-verified). Merge does not approve the deviations or welcome baseline replacement below.
  - [x] Contents/saved-places panel and typography popover implemented.
    - Produced: Iced-shaped Contents panel (heading/subheading/close, 12 px per-level indent, 38-character truncation, chapter-number fallback for untitled entries, current-entry treatment and reveal), saved-places section (count, empty state, title/page/note rows, note edit through the controller-owned dialog, delete), typography panel (EPUB font size ±2 clamped 8–48 with px label, line spacing cycle, theme cycle; raster zoom ±0.25 clamped 0.25–5.0 and fit width/page) and the more panel (page input with inline validation, bookmark toggle, open book, search toggle) plus the independent search bar. Entries, progress and tabs remain fixture-injected; the real TOC is 5E, live ranges 5G, sessions 5F.
  - [x] Panel states/actions verified; export scope and mode-specific controls recorded. Final parity revision [0cbd1b5c](https://github.com/chaba-dev/shosai/commit/0cbd1b5cc89834e23b72e95ea07bb7cfb63fc965): 709 passes / two skips, canonical checks clean, alpha-aware blank/transparent raster controls, inspected ImageMagick-verified composites and harness walkthrough, Oracle no blockers. Published test-only cleanup fix [94309198](https://github.com/chaba-dev/shosai/commit/94309198a24f663279a04f6b4bfd987194dba24f) tolerates vanished temporary-database entries without suppressing other errors: Linux 711 passes / two skips, macOS CI 709 passes / four skips, all 15 CI checks green. Earlier results below describe intermediate revisions, not the final head.
    - Produced: `test/reader/reader_panels_test.dart` (20 rendered-control tests: entry activation, loading/empty/failed/retry, stale-load rejection, saved-place delete, note dialog, export success/failure with notice, EPUB/raster availability, clamps, relayout gating, page-input conversion and validation, picker selection/cancellation, picker-slot retirement on suspension, stale-export rejection, current-entry reveal, search submit/step-wrap/close-cancel/no-matches/failure) and `test/visual/reader_panels_render_test.dart` (12 inspected renders at `W1280`/`C390`, `EN`/`JA`, `T100`/`T200`, two runs byte-identical); `make test-flutter` (697 passing), `lint-flutter`, `check-fmt-flutter`, `check-theme-tokens`, `check-l10n-codegen` pass.
    - Matched-state parity evidence (`test/visual/reader_panel_parity_test.dart`, 10 captures + 1 negative control, all passing): every capture seeds a disposable store with the committed 1C fixture bytes, opens the book through the real bridge, renders the production shell at the reference viewport/DPR/locale with the reference's panel, location, bookmark, search and note-draft state (the search captures wait for the manifest's settled `1 / 16` with the next-result control enabled; the note capture enters the pinned `check the survey notes` draft), and asserts the panel composition against the pinned reference's own values — panel padding 14, heading spacing 2, child spacing 10, chapter row 27 / pitch 37, entry padding 10, saved-place header group at the entry's right edge (delete inset 10-11), entry-to-export gap 10, more row 58 wide / 88 compact, search bar 54 wide / 92 compact with the wide close control at the bar's 12 px right inset and the compact one left-aligned at 111, wide field 420, typography row 53. The document check reads the Rust chapter raster itself (a blank-raster negative control proves it discriminates), so chrome, edge glyphs, the search bar or the note dialog's scrim cannot satisfy it. Artifacts: `.amp/in/artifacts/4c-parity/` (PNG + JSON sidecar per capture with the reference id/hash, fixture hash, geometry, spacing comparison, raster-ink count, delete-glyph ink box and defect list) and the labeled `Iced top / Flutter bottom` full-frame and 2x crop composites in `.amp/in/artifacts/4c-parity/matched/` (with a provenance table: reference sha256, fixture sha256, viewport, DPR, locale, Flutter revision). The reference PNG's manifest byte length and pixel size are re-verified per run, and the fixture byte length against the manifest. The reader is torn down inside each capture so its document handle is released before the next open.
    - 4C-owned differences fixed from this evidence: the typography row painted the Iced layout constant (62) instead of the reference's rendered height (52-53); the saved-place links kept the component layer's 36 px minimum instead of the reference's content height; the saved-place page/delete group was left-packed instead of sitting at the entry's right edge; the saved-place entries and the export action had no 10 px column spacing; the export action rendered 42 px instead of 37; the wide search bar's capped field left the count/previous/next/close group ~147 px short of the reference's right padding edge (the pinned render gives the field half the bar's free space and paints it 557 px wide, while the token `layout.readerPanel.searchInputMaxWidth` says 420; Flutter mirrors the render and the token/render discrepancy is flagged to the token owner); the delete control's 10 px `✕` text glyph was illegible (now the bundled icon font's `x` at 12 px in the reference's `[4, 6]` button, ink box 28×28 at 4x with its `Delete Pg 2` accessible name); the Japanese panel copy had drifted from the pinned locale files (`reading`, `no-bookmarks`, `bookmark-empty-hint`, `page-abbreviated`, `edit-note`, `add-note`, `no-results`) and the shared note dialog hardcoded `Save`/`Cancel`, so the catalogs now carry the reference's Japanese strings and localized dialog actions.
    - Recorded intentional deviations (each needs owner approval, per the plan's difference policy): the retained current-entry highlight (contract §4.6 requires it; the pinned reference marks no current chapter); the EPUB line-spacing control (contract §4.8 requires it; the reference fixes line spacing at 1.6 with no control); the missing `Paginated`/`Continuous` toggle (renderer work, 5H); the note editor as the controller-injected dialog (contract §4.7) where Iced edits inline; the search input's visible border and leading search icon where the reference's field blends into the bar; the pinned Iced app never overrode its text-input style, so its focused field paints Iced's default blue ring, which is not a Shōsai token, while Flutter paints the mapped component border/ring (a focus-ring token would be a 2C/owner decision); the compact more/search rows rendering 88/92 against the reference's fixed 84/88 (Flutter sizes to content instead of centring 3-4 px of overflow); the interface line box placing panel text ink 2-3 px lower than Iced's font stack while every spacing value matches exactly; and the reader chrome above the panel being 4B geometry (panel top 108 in Flutter versus 91 in the reference, excluded from the panel-relative comparison).
    - Disclosed document capability gap (observed, not hidden): the Rust document rasterizer registers only its math face for a document that declares no font faces, so `slow-rivers.epub` (EN) paints legible Latin text while `mizu-no-kioku.epub` (JA) paints missing-glyph boxes. The missing capability is document fallback-font coverage for CJK (typography.md keeps the book-content role separate from interface fonts), owned by 5C (FM-22); the captures keep the truthful output and the parity assertions compare the chrome/panel, not the document text. Real pagination, page box, spreads, TOC/session sources and page ordinals remain 5A/5E/5F/5G.
    - Oracle review: round 1 reported three blocking findings — (a) an invalidated document picker retained its modal slot after suspension/replacement, (b) a stale export still reached the sink and had no bridge-operation accounting, (c) the Contents current-entry reveal required the row context during build so an asynchronous load never scheduled it. All fixed with regression tests (see above); round 2 found no blockers. Each regression test was checked for discrimination (the reveal test fails with the reveal disabled). A follow-up round reviewed the parity-evidence work and its findings are recorded with the fixes in the package thread.
    - Recorded scope decisions: Markdown export delivery is **clipboard + brief notice** through the application notice center (contract §9.2 item 1; the shell now injects its reporter and a `file_selector` document picker into the reader); the Iced reading-mode (Paginated/Continuous) toggle is **not** rendered because switching the live mode is renderer work (5H) and mode-specific availability is derived from the document format; the theme cycle changes the reader chrome/surfaces and the persisted value is 5A/6B, while applying the palette to the rendered document remains 5A/5G (the renderer takes no palette input today); Enter submits the query and the explicit previous/next controls step results (the Iced debounced live search and Enter-steps-next are folded into that recorded difference); note creation at the current location is two-step (bookmark, then Add note), matching Iced.
    - Identified follow-up needing owner baseline approval (not changed here): the Iced no-document welcome composition (`welcome_view`: 32 px title, 16 px message, `Open File` picker action) replaces the retained welcome copy, which would invalidate the 2B-approved `reader-welcome-1280` golden. 4C does not regenerate that baseline; the item needs an owner-approved baseline replacement (owner of the welcome surface) before it can land.
- [ ] **4D accepted — selection presentation** — IN PROGRESS — implementation and evidence merged in [PR #133](https://github.com/chaba-dev/shosai/pull/133) as [6514f5de](https://github.com/chaba-dev/shosai/commit/6514f5de62caecaf781edee0774bc3880ff95bf5), 15 green CI checks, 2026-09-28. [Implementation thread](https://ampcode.com/threads/T-01a0e52f-cedb-7010-bcac-0ec4048f6c54) archived; `shosai-4d-reader` removed; publication branch deleted; evidence/scripts/unpublished closeout retained at `target/4d-final-evidence` (167 manifest entries verified). Explicit package acceptance and baseline decisions remain unapproved; merge does not waive the gaps below.
  - [x] Selection actions and annotation menus implemented without losing existing behavior; re-verified at revision `05adf79833f6` for the owner-approved light-chrome/document-palette separation (see the reopened-and-re-verified paragraph below).
    - Authority matrix (recorded before any visual change): **RD-12 has no Iced counterpart** — its authority is RFD 6 plus the retained Flutter implementation (plan decision 8; the 1C non-Iced authority record), so no Iced selection baseline is invented. The **shared chrome** the selection surface sits on does have pinned references (`rd-chrome-w1280-en`, `rd-chrome-c390-ja`, `rd-chrome-theme-dark-w1280-en`, `rd-chrome-theme-sepia-w1280-en`), so those states are compared as matched measurements. The **reader palette** states initially disagreed between the two authorities (the pinned reference keeps the chrome on the application palette in every reader theme; the 2C mapping themed the whole reader); that disagreement was measured and recorded, then **resolved by the owner decision of 2026-09-28** (below) rather than silently absorbed.
    - Produced (implementation): the annotation action set salvaged from #114 — the card's secondary-click menu (`Change color` / `Edit note` / `Delete highlight`, same gating, same messages as the inline controls, `tapEnabled: false`/`longPressEnabled: false` so the retained gestures are untouched) with the keyboard equivalents the contract requires (ContextMenu key or Shift+F10 while a control in the card has focus); the card's inline controls stay the primary, Tab-reachable actions. The #114 visual ancestors (badges, separators, default Shad composition) are not restored. The action surface is now positioned from the selected range through the rendered content box's own transform, so it follows the range in every fit (EPUB contain, PDF fit page/width/manual) and while the content is scrolled, instead of assuming the content box equals the viewport, and it stays clamped inside the viewport. The 4D copy is localized (14 new keys in `app_en.arb`/`app_ja.arb` + regenerated localizations: selection actions, color names, highlight label, resolution suffixes, menu entries), and the annotation navigate button uses the shared scaled-button height so 200% text is not clipped — a defect the RD-15 `T200` render found (`clippedText` on `ハイライト1`) and this package fixed.
    - Produced (tests): `test/reader/reader_selection_test.dart` (23 rendered-control tests through the production shell: mouse drag → action surface; Copy gating for a non-copy-eligible surface and copy delivery through the injected copier; each of the five RFD 6 colors committing its own color and range; Enter commit and Escape cancel; Shift+arrows extending without paging; F10 and the ContextMenu key focusing the actions and Escape dismissing them from inside; the screen-reader select action; tap-outside dismissal; the viewport clamp; the range-relative surface in a PDF fit-width view; the surface following the range when the content scrolls; Add note through the controller-owned dialog (save and cancel); the selection live-region error; annotation navigate/recolor/note/delete through the strip; the salvaged menu by secondary click and by Shift+F10, with a menu item activated through the keyboard; an open menu keeping its annotation when an earlier one is deleted; the annotation live-region error). The selectable-surface fixture is `test/support/selection_surface_fixture.dart`; the surface's real geometry is exercised by the parity captures, not by the fixture. The two new regression tests were checked for discrimination: removing the card key and disabling the geometry invalidation each make their test fail.
  - [x] Pointer/keyboard actions tested; compact, expanded, large-text and palette renders inspected. Re-verified for the palette correction at revision `05adf79833f6` (753 passing / 2 skipped, canonical checks clean, repeat-identical renders/parity/walkthrough, Oracle clear); the pre-change counts below are historical.
    - **Reopened and re-verified for the current theme changes (2026-09-28, revision `05adf79833f6`):** the earlier 752-pass suite and repeated evidence below were produced before the owner-approved palette correction; the results in this paragraph supersede their counts and values. The worker reproduced the reported `reader-welcome-1280` golden failure (0.20%, 2,051 px) and traced it by pixel measurement to the document-area text leaves inheriting the light chrome foreground: the no-document welcome copy and the failed-chapter message replace document content on document paper, so they now take `pageColors(theme).foreground`, with the document backdrop (`pageColors(theme).background`) painted behind the reader surface and its edge columns. That classification keeps the owner decision limited to the shared chrome, so the golden passes unchanged and no baseline replacement was needed or installed. Current results: `make test-flutter` 753 passing / 2 skipped / zero failures (including the new `dark reader keeps the no-document body legible` and `dark reader keeps the failed-document message legible` tests, both mutation-checked to fail with the fix reverted); `lint-flutter`, `check-fmt-flutter`, `check-theme-tokens` and `check-l10n-codegen` clean; the render suite (11 + 11 PNGs), the parity suite (4 + 4) and the walkthrough frames (8 + 8) byte-identical across two independent runs at revision `05adf79833f6` (the working copy has since advanced by documentation-only edits — this plan and the contract §5.5 clarification — which do not change the verified code); the matched composites (`Iced top / Flutter bottom`), the 2x header crops and the assertion-backed walkthrough were rebuilt with ImageMagick and re-verified (16 inserted regions and 8 contact-sheet tiles pixel-identical, independently re-checked on the delivered files). Oracle round 4 (theme-fix review) found one blocker — the document-area text leaves above — fixed and closed by round 5 with no remaining blockers. The inherited 4B chrome-height offset, the missing page box/spread/footer (5A/5B/5G/5H) and the CJK document-font fallback gap (5C/FM-22) remain disclosed and unchanged.
    - Produced: `test/visual/reader_selection_render_test.dart` (11 candidate renders, inspected: selection actions at `W1280`/`C390`, `EN`/`JA`, `T100`/`T200`, light/dark/sepia and `D2` at DPR 2 — captured at the device pixel ratio, not a 1x capture of a 2x viewport — plus the annotation strip in all three palettes and the annotation menu in `EN` and compact `JA` `T200`), plus `test/visual/reader_selection_walkthrough_test.dart` (8 assertion-backed frames captured only after each step's assertion, composed into the labelled GIF and contact sheet); `make test-flutter` (752 passing, 2 skipped), `lint-flutter`, `check-fmt-flutter`, `check-theme-tokens`, `check-l10n-codegen` pass; the render suite (11 + 11 PNGs), the parity suite (4 + 4) and the walkthrough frames (8 + 8) are byte-identical across two independent runs.
    - Matched-state parity evidence (`test/visual/reader_selection_parity_test.dart`, 4 captures + 1 negative control, all passing): every capture reproduces a pinned 1C state with the committed fixture bytes, locale, viewport, DPR, document, location, palette and one tab, opens the book through the **real Rust bridge**, drags a real range on the real chapter surface and seeds a real highlight, then measures both rendered images with the same routine: center-column color runs (one image-boundary rule on both sides), modal chrome surface, modal document paper, and one action label (`Aa`) inside its own interior region on each side — the reference's pinned region (the immutable, hash-verified capture's own `Aa` cluster) and Flutter's rendered `Aa` control rect, inset so a control border cannot be mistaken for the label. The label measurement reports its ink pixels and the contrast between its darkest ink and the band's modal background, with any deviation counting as ink, so a label painted *in* the surface color is measured rather than hidden. Matched exactly: document paper in all three palettes (`255,255,255` light, `31,31,36` dark, `245,235,214` sepia), chrome surface (`255,254,251` in every palette, delta 0), and the label contrast in every palette — light, dark and sepia all measure `645` on both sides after the 2026-09-28 chrome correction (89 ink pixels in the wide captures, reference 89 / Flutter 89, and 176/89 in compact `JA`; darkest ink `40,39,36` on both sides), with the label ink asserted to paint ink rather than a border. Recorded, not asserted equal: the inherited 4B chrome rows (header 52 reference vs 61 rendered, tab strip 35 vs 48, document top 90 vs 111 — 4C recorded the same offset as panel top 91 vs 108; widget bounds are kept as diagnostics and the comparison uses the image rule on both sides), and the document area is compared by palette and real Rust ink rather than by page composition because there is no page box, spread or footer yet (5A/5B/5G/5H). Artifacts: `.amp/in/artifacts/4d-parity/` (PNG + JSON sidecar per capture with the reference id/hash, fixture hash, palette, Flutter-only state list, both sides' measured regions and values, and the comparison), `.amp/in/artifacts/4d-renders/` and `-repeat/` for the render suite (11 + 11 PNGs byte-identical), and the labeled `Iced top / Flutter bottom` composites plus the assertion-backed walkthrough in `.amp/in/artifacts/4d-parity/matched/` and `.../walkthrough/` (provenance table; `magick compare -metric AE` verified all 16 inserted regions and all 8 walkthrough tiles pixel-identical to their sources).
    - **Resolved finding (owner decision 2026-09-28): the shared reader chrome stays light in every reader theme.** In the dark reader palette the chrome kept the pinned application *surface* (`255,254,251`, matching the reference) but its control labels followed the reader theme, so the `Aa` label was painted in the dark theme's foreground (`250,250,249`): the measured label contrast against the surface was **11** where the pinned reference measures **645** — effectively invisible — and the sepia chrome text was the reader ink (`77,51,26`, contrast `606`) instead of the application ink (`40,39,36`, `645`). The owner resolved the authority conflict by keeping the shared reader chrome on the pinned Iced application palette in every reader theme, matching the references (which recolor only the page), and reserving the reader palettes for the **document area**. Implemented at the owning theme/token boundary in `flutter/lib/app_theme.dart`: `shosaiReaderColorScheme`/`shosaiReaderShadTheme`/`shosaiReaderMaterialColorScheme` return the application (light) palette for every reader theme, `shosaiReaderDocumentColors` (and `pageColors`) is the reader document palette, and `_readerBody` paints the document row (page surface, edge columns, the no-document welcome body and the failed-chapter message) with that document paper and foreground, preserving the pre-decision document-area backdrop and the 2B welcome background. Document-theme behavior is unchanged (`pageColors`: `255,255,255`/`31,31,36`/`245,235,214`) and the inherited 4B chrome-height offset stays a separate, still-recorded item. Re-measured after the fix: chrome surface delta 0 in all three palettes, document paper delta 0, and the `Aa` label contrast **645** on both sides in light, dark and sepia (89 ink pixels in the wide captures, 176/89 in compact `JA`), so the parity suite now asserts the strong contrast in every palette instead of recording a deviation. The negative control blanks the pinned label region (adjacent controls untouched) and requires zero ink, so the label assertions cannot be satisfied without measuring the label.
    - Disclosed Flutter-only states (no Iced counterpart, named in every parity sidecar): the selection action surface and the annotation strip (RD-12/RFD 6). The document capability boundary is unchanged and not hidden: the Rust chapter surface renders real text, but there is no page box, spread or footer (5A/5B/5G/5H), and the CJK document-font fallback gap (`mizu-no-kioku.epub` paints missing-glyph boxes; 5C/FM-22) is inherited from 4C.
    - Oracle review: round 1 reported three blocking findings. (a) The action surface's position was a snapshot: a scroll or a height-only resize left it where it was first placed (and the fit-width test used the manual-zoom sentinel). Fixed with a content-geometry invalidation (a `NotificationListener<Notification>` — `ScrollMetricsNotification` is not a `ScrollNotification` — plus a post-layout content-size probe inside the sized content box, both bumping a notifier the overlay rebuilds from), a corrected fit-width test (`pdfZoom: -1`) and new scroll-follow and resize-clamp tests; each new test was checked for discrimination (the resize-clamp test fails with the narrow notification type, the scroll-follow test fails with the invalidation disabled). (b) The stateful annotation cards were unkeyed, so an open menu could migrate to another annotation after an earlier one was deleted. Fixed with `ValueKey(annotation.id)` on the card plus a regression test that fails without the key. (c) The parity evidence did not measure what it claimed: the "label ink" probe read a control border rather than the label foreground (so it would also pass if the labels vanished), and the row deltas mixed an image rule for the reference with widget bounds for Flutter. Fixed by measuring one named label (`Aa`) inside its own interior region on each side (the pinned reference region and the rendered control's rect, inset from the borders), with any deviation counting as ink and the contrast against the band background classifying legibility, plus a negative control that blanks the pinned label region and requires zero ink; and by applying one image-boundary rule to both sides while keeping widget bounds as diagnostics, with missing bands failing instead of becoming zero. Round 2 re-review closed the card-identity finding but found the geometry invalidation incomplete (the notification type could never match `ScrollMetricsNotification`, and the size probe read the scroll view's unbounded constraints) and the label probe still resolving to a trailing icon; both were fixed as described in (a) and (c) above, and round 3 found no remaining blockers. Round 4 (2026-09-28 theme-fix review) found one blocker: the document-area text leaves (no-document welcome copy, failed-chapter message) inherited the light chrome foreground, so a dark reader theme painted dark application ink on the dark document paper; fixed by giving those leaves `pageColors(theme).foreground` with the reader-paper backdrop behind them, plus two mutation-checked regression tests (`dark reader keeps the no-document body legible`, `dark reader keeps the failed-document message legible`). Round 5 confirmed the fix and reported no remaining blockers. Every finding's disposition is recorded here; none was waived.

| ID | Package | Depends on | Acceptance |
| --- | --- | --- | --- |
| 4A | Maintainer: typed presentation contract | 1A | Define component state/intents for header, tabs, Contents, saved places, typography, tools and progress. Specify fixture versus live capabilities; align durable navigation with 5A before integration. No widget-owned effects. |
| 4B | Header, tab strip, progress and edge navigation | 1C, 2C, 4A | Quiet composition, title truncation policy, disabled/loading states, keyboard navigation and intent tests through rendered controls. Tab overflow follows decision 11: one horizontally scrollable row with active-tab reveal and accessible close actions. |
| 4C | Contents/saved-places panel and typography popover | 4B | Selected entry, open/closed/empty/loading/error states; bookmark actions, note editing/deletion and Markdown export parity or named exclusion. Mode-specific control availability is explicit. |
| 4D | Selection actions, annotation menus and component acceptance | 4C | Preserve useful #114 context actions and keyboard equivalents. Inspect compact/expanded, large-text and palette states. Preserve current selection behavior; new cross-fragment integration belongs to 5I. |

### Stage exit checklist

- [ ] Components match their reference and dispatch correct intents from immutable fixtures.
- [ ] Fixture-only capabilities clearly identified; live paginated integration remains owned by 5G.
- [ ] All four packages accepted with evidence linked above.

## Stage 5 — Deliver reader capabilities

**Maintainer or stronger-model design is required for 5A and 5F's lifecycle
contract.** Lower-tier workers implement bounded pieces after interfaces, fixtures
and expected results are frozen. Split rich composition by the packages below;
do not assign the whole renderer as one task.

### Delivery checklist

- [x] **5A accepted — renderer/persistence contract** — DONE — owner accepted in the [parent thread](https://ampcode.com/threads/T-01a0e675-f4f2-7202-8eef-bdd8ca70b093); [PR #134](https://github.com/chaba-dev/shosai/pull/134) merged at [154088a4](https://github.com/chaba-dev/shosai/commit/154088a44ade72ffc77f18c98933f8f3e7c7824e) on 2026-09-28T05:17:09Z, with stronger-model design and [independent vectors](renderer-contract-fixtures.json) from isolated `shosai-5a-contract`. The 2026-09-28 adoption decision supersedes the contract's Rust-specific EPUB renderer/persistence portions (see the adoption handoff above) without erasing this acceptance; its behavioral rules and PDF/CBZ portions remain in force. The superseded 5B package is not a consumer; any later consumer of the reviewed behavioral rules must be named explicitly and may use them only after its own authorization.
  - [x] Addresses, layout identity, DTOs, extraction/mapping and persistence rules specified in [renderer/persistence contract](flutter-renderer-persistence-contract.md), including atomic publication, bounded viewport discovery, geometry-only PDF projection and typed zoom inheritance without SQL migration. The merged Dart evaluation did not override Rust ownership when this contract was written; the 2026-09-28 EPUB adoption decision now supersedes its Rust-ownership statements for EPUB (see the adoption handoff above), while its durability, atomicity, bounded-work and persistence rules still apply to whatever renders EPUB and remain in force for PDF/CBZ. This supersession does not reopen the 5A acceptance.
  - [x] Contract and [independent fixture expectations](renderer-contract-fixtures.json) reviewed before consumer work. Oracle round 1 found three blockers (clear-fit fallback, missing viewport discovery and geometry-only PDF projection); all corrected with discriminating vectors. Round 2 at local revision `553b25af` closed all findings, no blockers; its optional cursor clarification is incorporated. `python3 scripts/check_renderer_contract.py` passes vectors, 12 negative controls, 15 existing conformance hashes, local links and the 30-package accounting (3 accepted when this check ran; 4 once the 5A acceptance recorded here is counted); rerun after editorial closeout. No renderer, database round-trip, performance or visual pass is claimed. The real long-chapter/legacy-store tests, EN/JA readability calibration and measured prototype described in contract §8 were 5B's scope; with 5B superseded they belong to the replacement EPUB engine slices (or a named later package), and none of that evidence is claimed here. Inherited gaps and all other still-unchecked package acceptance checks remain open.
- [ ] **5B accepted — pagination prototype** — SUPERSEDED/PAUSED — the 2026-09-28 EPUB adoption decision replaces the Rust pagination/bridge-transport package with the Dart EPUB engine slices, so 5B is not dispatched and is not resumed. The package was never delivered: both children stay unchecked and no acceptance is recorded. The local `shosai-5b-pagination` workspace is paused reference work; the 5A contract, its independent vectors and the Phase C measurements are retained as historical evidence, not as a 5B pass. Historical context: the package was to own core pagination, bridge transport and the measured prototype described in contract §8.
  - [ ] Bounded pagination, bridge transport and legacy persistence handling implemented.
  - [ ] Long-chapter/round-trip tests pass; prototype measurements recorded against budgets.
- [ ] **5C accepted — rich text/blocks**
  - [ ] Styled blocks, bidi and embedded-font composition implemented.
  - [ ] Conformance fixtures verified against independent layout/content expectations.
- [ ] **5D accepted — images/tables/math**
  - [ ] Image, table, math, fallback and palette composition implemented.
  - [ ] Full-color output and canonical-to-visible text mapping verified.
- [ ] **5E accepted — navigation and sidecars**
  - [ ] Durable navigation, selection geometry and semantic sidecars implemented.
  - [ ] Resolution, scheme restrictions and geometry/semantic consistency tests pass.
- [ ] **5F accepted — tab/session lifecycle**
  - [ ] Lifecycle policy frozen and tab-scoped routing, saves/effects/resources implemented.
  - [ ] Delayed-effect, close/reopen/removal, restoration and disposal tests pass.
- [ ] **5G accepted — paginated integration**
  - [ ] Real capabilities connected to reader presentation without monochrome EPUB tinting.
  - [ ] Live tab/navigation/typography/selection/semantic actions tested; renders inspected.
- [ ] **5H accepted — continuous modes and spreads**
  - [ ] Separate EPUB continuous tiles, EPUB/PDF/CBZ two-page spreads and typed zoom/fit implemented.
  - [ ] All six mode combinations, seam checks and position-preserving switches verified.
  - [ ] EPUB shows two distinct consecutive pages in wide paginated mode; narrow/wide transitions preserve location. Inspect first/last spread, odd page count and large-font states.
- [ ] **5I accepted — cross-fragment interaction**
  - [ ] Durable cross-fragment selection, tile overlays and virtualized semantics implemented.
  - [ ] Clamps, quote/copy, eviction/repagination and accessibility focus/order verified.
- [ ] **5J accepted — reader quality and stress**
  - [ ] Rich-content, multi-tab, continuous-cache and spread measurements/evidence produced.
  - [ ] Quality inspected; budgets met or changes approved; rejection tests distinguished from defects.

| ID | Scope and ownership | Depends on | Acceptance |
| --- | --- | --- | --- |
| 5A | Core/bridge renderer and persistence contract | 1A | Freeze addresses, layout identity, atomic publication, bounded extraction, semantic/text mapping, continuous-tile coordinates and mode/zoom persistence. Publish DTOs and independent fixture expectations before consumers start. |
| 5B | Core pagination, bridge transport and measured prototype | 5A | **Superseded 2026-09-28** by the EPUB adoption decision and retained as reference evidence; not dispatched. Historical acceptance: long chapters render bounded pages; progress and legacy reading state remain correct. Measure raster production, transfer, decode, warm turns, relayout and retained memory. Generate bindings once under one owner. |
| 5C | Rich text/block composition | EPUB engine slices (replaces 5B) | Computed styles, headings, emphasis, links, code, lists, nested quotes/figures, captions, rules, alignment/direction, bidi and isolated embedded fonts. Reuse existing conformance fixtures. |
| 5D | Image, table and math composition | 5C | Images/fallbacks, tables, inline/display math and page palettes; verify canonical-to-visible text mapping and full-color output. |
| 5E | Navigation, selection geometry and semantic sidecars | 5D | TOC/internal links resolve to durable positions; restricted external schemes preserved; hit zones, carets, roles, labels/actions and reading order derive from the same layout as pixels. |
| 5F | Tab/session lifecycle and shell routing | 4A, 5A | Session survives library navigation; per-tab saves/effects/resources; duplicate-open, close, removal, last-tab and restoration behavior explicitly tested. |
| 5G | Initial paginated reader integration | 4D, 5E, 5F | Real tabs, TOC/link activation, typography, progress, selection and semantic actions. Preserve document colors: do not tint composited RGBA EPUB pages with the old monochrome paint path. |
| 5H | Continuous modes, EPUB/PDF/CBZ spreads and typed zoom/fit | 5G | All six format/mode combinations work; EPUB continuous uses separate layout tiles. Preserve position on switching mode/fit/scale. Required EPUB two-page spreads and decision 12's readability fallback must pass without reducing the chosen font size; permanently single-page capability is not acceptable. |
| 5I | Cross-fragment selection and virtualized accessibility | 5H | Durable ranges and per-tile overlays survive eviction/repagination; chapter/page clamps, quote/copy extraction, semantic focus/order tested through interaction. |
| 5J | Reader quality and stress acceptance | 5I, 1C | Re-measure rich content, multiple tabs, continuous caches and spreads; inspect matched-scale text and images; verify intended resource rejections separately. |

### Contract requirements for renderer consumers

The 5A contract's behavioral requirements below were written for the 5A–5B
renderer pair; 5B is superseded (2026-09-28) and the EPUB consumer is now the
Dart engine plus Flutter layout. The requirements stay binding for whatever
renders a format, with the ownership notes inline. PDF/CBZ keep the Rust
mechanisms named in the [renderer contract](flutter-renderer-persistence-contract.md).

- Separate ephemeral presentation addresses from durable EPUB spine/offset
  locations, with translation in both directions at the format's owner (the Dart
  engine for EPUB, Rust for PDF/CBZ). Never serialize a layout
  page index as a durable chapter or divide chapter index by page count for progress.
- Layout identity includes document generation, mode, logical width/height, DPR or
  raster scale distinct from document zoom, typography, palette and layout revision.
  Publish pixels, geometry, semantics and page/tile metadata under one identity.
- Report viewport height and DPR changes; settle resize requests and reject stale
  results without mixing metadata or surfaces. Retained pixels may scale during drag.
- Bound page/tile geometry, scalar work, endpoints, carets, pixels and retained
  resources. Do not remove admission limits to make long chapters pass. Replace
  whole-chapter selection/annotation extraction with bounded range-local operations.
- Preserve legacy chapter-plus-offset reading state, null offsets and saved zoom;
  no schema migration is intended. If one proves necessary, name and review it.
  Test pre-change databases in both frontends using disposable copies.
- Test search-result, bookmark, annotation and reading-state round trips across
  width and font changes; test visible navigation/overlays during 5G integration.
- Replace the `pdfZoom` sentinel with typed FitPage/FitWidth/Manual preferences for
  PDF/CBZ. Specify codec, legacy decoding, per-book versus default precedence and
  continuous-mode fit semantics before implementation. DPR is not persisted zoom.
  EPUB uses font size/line spacing rather than those zoom controls.
- Map canonical durable text to visible text explicitly, including image/math
  fallback text. Range extraction must not reconstruct quotes from whichever tiles
  happen to be retained. Cross-fragment selections store durable endpoints.
- Test a valid chapter exceeding the old 65,536-scalar and whole-chapter pixel
  ceilings; annotate a non-first page, reopen, evict and repaginate, then verify
  quote, range and projected highlight. Separately test hostile-input rejection.

### Continuous layout requirements for 5H–5I

EPUB continuous mode is a distinct layout owned by the format's renderer (the
Dart/Flutter layout for EPUB, Rust for PDF/CBZ), not stitched paginated pages.
Match Iced's column of chapters: 32px chapter spacing, 20px content padding, no page
boxes, per-page titles/margins or footers. Shared layout coordinates place bounded
fragments at integral device-pixel boundaries with zero inter-fragment gap. Chapter
spacing belongs to layout and appears exactly once.

Verify seams against an untiled render of the same small continuous fixture:
no missing/duplicated content, no artificial background band, unchanged line/block
positions across cuts, and no cumulative drift. Include cuts through styled text,
images and block spacing; do not assume every boundary has one normal line-height
gap. The reference need not allocate an unbounded real chapter.

Virtualize under a bounded cache. Resolve scroll position through layout coordinates
to a durable location; project durable highlights onto every visible fragment.
EPUB selection can span tiles within one spine item, clamps at its boundary, and
remains valid after eviction; PDF selection remains page-local. Test assistive
technology ordering and focus as retained tiles change, not only a static page label.

### Session requirements for 5F

Before implementation, freeze and test duplicate-open activation, adjacent-tab
selection on close, final-tab return to library, book removal while open, pending
save draining/failure behavior, and inactive-tab resource retention/eviction policy.
Scope effects by tab identity plus document generation and operation revision.
Closing a tab must not release a handle still in use or let its completion affect
another tab. Test delayed effects across close, reopen, switch and disposal.
Restore at most the last active book as one tab; each book keeps its durable location.

### Stage exit checklist

- [ ] EPUB paginated accepted with per-format evidence.
- [ ] EPUB continuous accepted with per-format evidence.
- [ ] PDF paginated accepted with per-format evidence.
- [ ] PDF continuous accepted with per-format evidence.
- [ ] CBZ paginated accepted with per-format evidence.
- [ ] CBZ continuous accepted with per-format evidence.
- [ ] Required two-page spreads verified for EPUB, PDF and CBZ; EPUB is not permanently single-page.
- [ ] Durable navigation, retained selection/restoration and bounded resources verified.
- [ ] Visual/semantic evidence approved; all ten packages accepted with evidence linked above.

Any temporary gap keeps its accepting package open.

## Stage 6 — Close workflow and acceptance gaps

### Delivery checklist

- [ ] **6A accepted — import workflow**
  - [ ] Full discovery/review workflow implemented; native providers retained, no planned feature exclusions.
  - [ ] Discovery, search, selection, cancellation and review acceptance checks pass.
- [ ] **6B accepted — settings workflow**
  - [ ] Language, library location, import behavior and reader defaults implemented in full.
  - [ ] Platform differences, persistence/precedence and immediate language updates verified.
- [ ] **6C accepted — end-to-end acceptance**
  - [ ] Cross-format visual/accessibility evidence and native smoke results produced.
  - [ ] Required locale, sizing, palette, keyboard and screen-reader checks pass and are reviewed.
- [ ] **6D accepted — final records and PR disposition**
  - [ ] Governing records/evidence reconciled; remaining remote actions explicitly authorized.
  - [ ] Approved PR cleanup completed and recorded; no temporary gap presented as complete.

| ID | Package | Depends on | Acceptance |
| --- | --- | --- | --- |
| 6A | Import discovery/review workflow | 3D | Implement staged discovery, search, selection, cancellation and review matching Iced's capabilities; preserve native providers. No planned feature exclusions; platform-specific controls must preserve capability. |
| 6B | Settings workflow | 3D, 5A | Cover language, library location, import behavior and reader defaults; define supported platform differences. Test persistence/default precedence and immediate language updates. |
| 6C | End-to-end accessibility and visual acceptance | 6A, 6B, 5J | English/Japanese/mixed text, compact/expanded, high DPR, 200% text, palette states, keyboard and named platform screen-reader checks. Real adapters except lowest platform boundary in widget tests; native smoke checks separately. |
| 6D | Final records and approved PR cleanup | 6C, 1D, 2D | Reconcile checklist, evidence, retained PR behavior and governing records; request approval for remaining remote actions. |

### Stage exit checklist

- [ ] All acceptance rows pass or have owner-approved permanent differences.
- [ ] All six required format/mode combinations pass; no temporary gaps remain.
- [ ] Full import/settings capabilities pass; platform adaptations preserve behavior. Any unavoidable limitation has a new explicit owner decision, not an assumed exclusion.
- [ ] Any performance budget changes explicitly approved.
- [ ] Decisions and evidence links preserved in governing records before plan retirement.
- [ ] All four packages accepted with evidence linked above.

## Delegation contract

Each package must receive a concrete task brief before dispatch. Tables establish
scope and dependencies; they are not permission for workers to invent interfaces.

Owner instruction (2026-09-20): implementation workers must request Oracle review
of their changes, disclose every finding, fix findings with regression tests, and
repeat review/fix cycles until no issues remain before preparing their PR. Record
every review round, disposition, test and limitation; do not silently waive findings.
Create separate PRs concurrently only for independent, disjoint work; wait for
prerequisites when sequential. This authorizes scoped implementation PR creation,
not merging, rewriting existing PRs, deploying or changing shared data.

```text
Implement package <ID> from docs/flutter-ui-restoration-plan.md in shosai.
Starting revision: <exact local integration revision and remote base>.
Prerequisites: <completed package IDs and interface/evidence paths>.
Owned files: <explicit paths>; coordinate any additional write target.
Reference: <capture/checklist rows, state fixtures and frozen values>.
Required behavior: <inputs, typed intents, outputs and invariants>.
Preserve: <existing capabilities>; non-goals: <explicit exclusions>.
Verification: <targeted commands, independent expected results, rendered states>.
Inspect screenshots; report failures and limitations, not just generated artifacts.
Do not approve your own product exclusions or regenerate goldens as proof of parity.
Update this plan's package checklist as deliverables and verification finish.
Record owner/thread, blockers and evidence; update stage/overall counts on acceptance.
Report changed files, tests, inspected evidence and unmet acceptance criteria.
Do the assigned work directly; do not create another thread for this package.
Do not push, rewrite/close PRs, merge or change shared data without authorization.
```

Use lower-tier models for token mappings, bounded widgets, fixture cases and
implementations against frozen contracts. Keep unresolved renderer/persistence and
tab-lifecycle decisions with a maintainer or stronger model. Review intent and
evidence before integration; preserve generation/ownership tests rather than
replacing them wholesale. Mark a package complete only after its accepting checks
run and its required screenshots are inspected. Record a verification blocker as a
blocker, never as a passing gate.

### Parity evidence gate (every parity package)

A parity package is not visually ready until it carries inspected, matched-state
Iced/Flutter evidence. Package acceptance does not transfer to another package.

- **Reproduce the reference state.** Use the committed capture's own fixture
  bytes, locale, viewport, device-pixel ratio and text scale, and the same
  document, panel, tab, bookmark, note and search state the capture manifest
  records. Cite the reference id and its manifest hash. A similar-looking state
  is not the reference state.
- **Render the compared surface through its production path.** A chrome/panel
  comparison must render the production shell and, for a loaded-document state,
  the real document rendering; a placeholder, stub or painted stand-in is not
  parity evidence, and a loaded-document capture whose document area paints
  nothing fails the comparison. States that legitimately have no document
  (welcome, opening, open failure, empty library) are compared as what they are.
  Contract-sanctioned fixture-only surfaces stay permitted when the capture
  declares them: 4A allows fixture-injected tabs, Contents entries, progress
  ordinals and search results until 5E/5F/5G/5H supply the live sources, and a
  parity capture must name the injected source rather than hide it.
- **Measure, then inspect.** Record the chrome/panel values on both sides (row
  heights, paddings, row pitch, control positions) and inspect side-by-side
  crops of every compared state. "No detector defect" is not an ink review, and
  a green metric does not replace looking at the images.
- **Separate capability gaps from chrome differences.** When a Stage 5
  capability (page box, pagination, spreads, real TOC/session sources, document
  font fallback) cannot render yet, state the exact boundary and its owner, keep
  the truthful rendering, and compare only what both sides actually render.
  Never hide a gap behind a fabricated surface.
- **Record every intentional deviation** with its contract/reference rationale
  and owning package: a difference that is neither matched nor recorded is a
  defect. Tolerances must be justified by measured toolkit rasterization, never
  chosen to make a check pass.
- **Cover the reference matrix where it exists** (wide/compact, EN/JA, and
  T100/T200 only where the reference has them) and name the states that are
  Flutter-only.

## First dispatch and historical crosswalk

**Current work: the bounded EPUB engine slices from the 2026-09-28 adoption decision; 1A/1B/2A/5A fully accepted, 4/30.**
2C, 3A–3C and 4A–4D delivery has merged; explicit acceptance/follow-ups remain
as checked above. 5A was accepted and merged at
[154088a4](https://github.com/chaba-dev/shosai/commit/154088a44ade72ffc77f18c98933f8f3e7c7824e);
the former 5B dispatch is superseded by the adoption decision and will
not start. The remaining native macOS picker check stays open and does not
become a pass by advancing the plan.

| Previous plan phase | New owner(s) |
| --- | --- |
| 1: tokens | 1A values; 2C implementation |
| 2: checklist and Iced capture | 1A–1C |
| 3: pagination/addressing | 5A; 5B superseded → EPUB engine slices |
| 4: rich EPUB/navigation/semantics | 5C–5E |
| 5: library | 3A–3D; 6A–6B for full import/settings |
| 6: reader/model | 4A–4D, 5F–5G |
| 7: modes/spreads | 5H–5J |
| 8: harness | 2B, 6C |
| 9a: crash-fix bootstrap | 1A baseline; 2A fix; no universal remote-merge gate |
| 9b: keepers/records | 2D, 1D, 6D; mandatory stack-CI expansion removed |

The September 20 restructuring supersedes the old phase numbering, contradictory
dispatch ordering, paginated-page stitching prescription and blanket rejection of
#114. The accepted product direction remains Iced-shaped UI/UX with worthwhile
Flutter improvements retained.
