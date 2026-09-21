# Flutter UI restoration plan

Restore Iced's information hierarchy and reading workflow in Flutter while keeping
useful Flutter capabilities. This is a presentation rebuild and targeted reader
contract work, not a frontend restart or pixel-identical port.

- Opened: 2026-09-14. Restructured: 2026-09-20.
- Status: Stages 1–2 in progress; 3/30 delivery packages accepted (1A, 1B, 2A). Current: 1C and 2B.
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
- [ ] Delivery packages accepted: 3/30 (tracked in the stage checklists below).
- [ ] Final restoration exit criteria met and governing records reconciled.

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
4. **Keep the Elm boundary and Rust document ownership.** Widgets render immutable
   state and dispatch typed messages. Controller-owned effects report guarded
   completions. Rust owns parsing, layout, durable anchors, persistence and admission.
5. **Use Rust-produced EPUB rasters with geometry and semantic sidecars.** This is
   the selected simplest encoding preserving Rust shaping, not the only possible
   encoding. Flutter must not independently reshape text against Rust hit zones.
   Font quality and performance must be measured, not inferred from library versions.
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
    to force a spread. Rust owns this layout choice. Package 5A defines the
    deterministic minimum usable column-width rule, calibrated with rendered
    English/Japanese and large-font fixtures in 5B; 5H verifies both sides of the
    boundary and durable-location preservation. The numeric threshold remains an
    engineering measurement, not a license to omit two-page support.
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
| 3. Library restoration | Iced-shaped library with working existing actions | 3A–3D | 0/4 | TODO |
| 4. Reader presentation | Verified reader components and typed presentation contract | 4A–4D | 0/4 | TODO |
| 5. Reader capabilities | Real sessions, rich EPUB, navigation, selection and reading modes | 5A–5J | 0/10 | TODO |
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
- 5A is the renderer contract milestone; 5B is the measured pagination milestone;
  5C–5E build rich composition; 5G integrates the initial paginated reader; 5H–5I
  deliver continuous/spread behavior. 5F supplies real tab/session lifecycle.
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
- [ ] **1C accepted — reader reference** — DELIVERED, OWNER DECISIONS OPEN — [PR #119](https://github.com/chaba-dev/shosai/pull/119), [DeepSeek on framework16](https://ampcode.com/threads/T-01a0c2bf-b12e-7578-9bd6-40491e118496). Coverage follow-up head [092d175](https://github.com/chaba-dev/shosai/commit/092d175280aa452f22a6e0c925013db1ec1ca87e); parent confirmed all listed CI checks pass except Flutter macOS host still running at review. Worker reports two follow-up Oracle rounds ending clean, after five initial rounds.
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
- [ ] **2B accepted — verification harness** — DELIVERED, ACCEPTANCE OPEN — [PR #120](https://github.com/chaba-dev/shosai/pull/120), [DeepSeek Linux implementation/validation](https://ampcode.com/threads/T-01a0c335-958f-7254-a60e-f8e17960a06a), [DeepSeek macOS fixes/verification](https://ampcode.com/threads/T-01a0c5f1-a66a-70bc-a689-66c6c65c8d09). Platform follow-up is based on [b9d1b8f](https://github.com/chaba-dev/shosai/commit/b9d1b8fb5f962485c5e2342c937fe2d2f39408ee); package acceptance is not implied by publication.
  - [x] Production-shell golden harness, bounded Linux native smoke runner and window-scoped macOS capture path implemented. Final reviewed platform patch SHA-256: `b3cb625d3e8d6a1d81374f070824e3400eabd601e49930fafa398ea77cf9bc12`. Workers report the Oracle loop closed with no blockers, 65 visual and 360 full-suite tests passing on Linux, 73 script tests passing with six macOS-only skips, and passing X11 picker dismissal/recovery. macOS reports 44/44 detector controls and 17/17 capture controls passing. Both platforms reproduce all 12 renders byte-identically; macOS reproducibility commands still exit 1 because visual assertions fail.
  - [ ] Known clipping/overflow regressions and native paths independently verified. Nine macOS visual states remain failing: four production clipping states require resolution or explicit owner disposition, and five states lack reviewed platform baselines. No tolerance widening, baseline approval or failure waiver has been granted. Accessibility and Screen Recording preflights pass, but Automation access to System Events remains missing; the corrected runner refuses without prompting or capturing. Native macOS dismissal, recovery and window-scoped screenshots remain unverified. Linux-recorded golden differences are not silently accepted as new baselines.
  - Deferred production defect: at 900×700 with 200% Japanese text, the floating Add books button overlaps the bottom-right card metadata. Stage 3 owns the layout fix; geometric clipping detectors do not claim to detect arbitrary overlap.
- [ ] **2C accepted — theme mappings**
  - [ ] Shared tokens and all Rust/Shad/Material mappings implemented.
  - [ ] Mapping/literal checks pass; palette renders inspected and baselines reviewed.
- [ ] **2D accepted — notices**
  - [ ] Retained notice infrastructure and persistent/transient feedback policy implemented.
  - [ ] Exactly-once notice tests pass; actionable failures remain visible.
  - [ ] Decision 13 tested: success toast expiry, persistent failure details/recovery, inline dialog errors, neutral cancellation and suppression of duplicate unresolved notices.

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

- [ ] **3A accepted — library navigation**
  - [ ] Header, wide sidebar and narrow filter row implemented; All/EPUB/PDF/CBZ and Settings accessible without a drawer.
  - [ ] Reference states, selected filters, keyboard focus and 200% text verified.
- [ ] **3B accepted — cards and grid**
  - [ ] Cover-first cards and responsive grid implemented with existing actions retained.
  - [ ] Missing covers, multilingual metadata, lazy loading, open/removal actions verified.
- [ ] **3C accepted — continue-reading and states**
  - [ ] Continue-reading, skeleton, empty, filtered-empty and failure/debt states implemented.
  - [ ] Correct book/position and each distinct collection state verified.
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

- [ ] **4A accepted — presentation contract**
  - [ ] Typed component state/intents and fixture/live boundaries specified.
  - [ ] Contract reviewed against Elm ownership and durable-navigation integration needs.
- [ ] **4B accepted — reader chrome**
  - [ ] Header, tab strip, progress and edge-navigation components implemented.
  - [ ] Fixture renders inspected; loading/disabled states and keyboard intents tested.
  - [ ] Many-tab overflow tested at wide/compact widths: one scrollable row, readable labels, active-tab reveal and keyboard activation/closing of initially offscreen tabs.
- [ ] **4C accepted — panels and typography**
  - [ ] Contents/saved-places panel and typography popover implemented.
  - [ ] Panel states/actions verified; export scope and mode-specific controls recorded.
- [ ] **4D accepted — selection presentation**
  - [ ] Selection actions and annotation menus implemented without losing existing behavior.
  - [ ] Pointer/keyboard actions tested; compact, expanded, large-text and palette renders inspected.

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

- [ ] **5A accepted — renderer/persistence contract**
  - [ ] Addresses, layout identity, DTOs, extraction/mapping and persistence rules specified.
  - [ ] Contract and independent fixture expectations reviewed before consumer work.
- [ ] **5B accepted — pagination prototype**
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
| 5B | Core pagination, bridge transport and measured prototype | 5A | Long chapters render bounded pages; progress and legacy reading state remain correct. Measure raster production, transfer, decode, warm turns, relayout and retained memory. Generate bindings once under one owner. |
| 5C | Rich text/block composition | 5B | Computed styles, headings, emphasis, links, code, lists, nested quotes/figures, captions, rules, alignment/direction, bidi and isolated embedded fonts. Reuse existing conformance fixtures. |
| 5D | Image, table and math composition | 5C | Images/fallbacks, tables, inline/display math and page palettes; verify canonical-to-visible text mapping and full-color output. |
| 5E | Navigation, selection geometry and semantic sidecars | 5D | TOC/internal links resolve to durable positions; restricted external schemes preserved; hit zones, carets, roles, labels/actions and reading order derive from the same layout as pixels. |
| 5F | Tab/session lifecycle and shell routing | 4A, 5A | Session survives library navigation; per-tab saves/effects/resources; duplicate-open, close, removal, last-tab and restoration behavior explicitly tested. |
| 5G | Initial paginated reader integration | 4D, 5E, 5F | Real tabs, TOC/link activation, typography, progress, selection and semantic actions. Preserve document colors: do not tint composited RGBA EPUB pages with the old monochrome paint path. |
| 5H | Continuous modes, EPUB/PDF/CBZ spreads and typed zoom/fit | 5G | All six format/mode combinations work; EPUB continuous uses separate layout tiles. Preserve position on switching mode/fit/scale. Required EPUB two-page spreads and decision 12's readability fallback must pass without reducing the chosen font size; permanently single-page capability is not acceptable. |
| 5I | Cross-fragment selection and virtualized accessibility | 5H | Durable ranges and per-tile overlays survive eviction/repagination; chapter/page clamps, quote/copy extraction, semantic focus/order tested through interaction. |
| 5J | Reader quality and stress acceptance | 5I, 1C | Re-measure rich content, multiple tabs, continuous caches and spreads; inspect matched-scale text and images; verify intended resource rejections separately. |

### Contract requirements for 5A–5B

- Separate ephemeral presentation addresses from durable EPUB spine/offset
  locations, with Rust translation in both directions. Never serialize a layout
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

EPUB continuous mode is a distinct Rust layout, not stitched paginated pages.
Match Iced's column of chapters: 32px chapter spacing, 20px content padding, no page
boxes, per-page titles/margins or footers. Shared layout coordinates place bounded
raster tiles at integral device-pixel boundaries with zero inter-tile gap. Chapter
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

## First dispatch and historical crosswalk

**Current packages: 1C and 2B (in progress); 1A/1B/2A accepted.** No implementation
package is complete merely because this plan exists. 2B uses the merged 2A
baseline without dialog/test ownership overlap; start library
restoration as soon as 1B/2C are accepted, independently of renderer completion.

| Previous plan phase | New owner(s) |
| --- | --- |
| 1: tokens | 1A values; 2C implementation |
| 2: checklist and Iced capture | 1A–1C |
| 3: pagination/addressing | 5A–5B |
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
