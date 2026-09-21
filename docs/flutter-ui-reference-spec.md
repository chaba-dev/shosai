# Flutter UI reference specification

Token and acceptance specification for the Flutter restoration described by
[the restoration plan](flutter-ui-restoration-plan.md). Owned by package 1A; it
freezes design values, states and acceptance rows so later packages implement and
verify against one list.

- Status: **ACCEPTED as the package 1A working contract by the owner on 2026-09-20; not approved implementation or capture evidence.** The 860 px breakpoint remains provisional; readability thresholds are calibrated in 5A/5B.
- Written: 2026-09-20. Revised 2026-09-20 for review corrections and plan
  decisions 11 (tab overflow), 12 (EPUB readability fallback) and 13 (notice
  policy). Supersedes nothing; the restoration plan remains authoritative for
  sequencing, dependencies and acceptance.
- Governing documents: [RFD 4](../rfd/0004/README.adoc), its
  [implementation checklist](../rfd/0004/IMPLEMENTATION.org),
  [RFD 6](../rfd/0006/README.adoc) for selection/highlighting, and the required
  [Flutter architecture](flutter-architecture.md) and [typography](typography.md)
  guidance.

**What this document is not.** No row here is accepted, and none of the captures it
names exist yet. Iced source values are transcribed facts; every named evidence
deliverable (`1B-*`, `1C-*`, `2B-GOLDEN`, `2C-PALETTE`, `6C-*`, the 6A/6B workflow
records) is currently **pending**, and `WT` rows are implemented tests that do not
exist yet either. Treat the whole document as an accepted specification, not as
evidence of parity.

## 1. Scope, authority and status

### 1.1 Authorities

| Authority | Meaning in this document |
| --- | --- |
| `Iced` | Design values and composition come from the Iced frontend in `crates/shosai-app`, at the pinned reference revision (§1.3). |
| `Retained Flutter` | Behavior exists in `flutter/lib` today and must survive restoration, with toolkit-appropriate presentation. |
| `RFD 6` | Selection/highlighting semantics come from RFD 6, not from Iced. |
| `Owner` | A product decision recorded in the restoration plan on 2026-09-20. |
| `Plan contract` | A requirement introduced by the restoration plan with **no Iced reference**; evidence must come from the later renderer/Flutter acceptance package. Rows using this authority cannot be satisfied by `1B-*`/`1C-*` Iced captures. |

When `Iced` and `Retained Flutter` conflict, the plan's decisions govern: Iced supplies
values and structure; retained Flutter supplies capability and accessibility. A
combined value such as `Iced + Owner` means the Iced composition is the base and the
owner decision recorded in the plan extends it (for example, retaining the CBZ filter
and a directly accessible Settings entry in the compact layout). Where a row extends
beyond Iced (CBZ filter entries, `T200` text scaling, raster tile seams), the
authority names the extending source explicitly and the row's evidence must come
from that source, not from an Iced capture.

### 1.2 Prerequisites and blockers (explicit)

| ID | Prerequisite | Status | Blocks |
| --- | --- | --- | --- |
| P1 | `.agents/dev jj` wrapper usable on this runner | **RESOLVED** (2026-09-20, parent): system-Nix PATH fallback; `jj 0.39.0` runs. | Baseline pin (§1.3) — now recorded |
| P2 | 1B/1C capture harness (`make reference-shots` or equivalent) | Not implemented | Every `1B-*`/`1C-*` evidence row |
| P3 | Capture manifest (revision, fixture hash, fonts, size, DPR) | Does not exist | Reference approval, reproduction checks |
| P4 | Library-state fixture or seed | Does not exist; `make reset` only deletes | Library capture rows |
| P5 | Fixture provenance records for committed fixtures (`sample.*`, test-only fonts, perf fixtures) | Research complete in the [fixture record](../crates/shosai-core/tests/fixtures/README.md); `sample.*` origins remain unverified. 1B/1C own documented capture fixtures; 2C owns outstanding font records (§5.2). | Fixture citations; redistributability claims |
| P6 | 2B production-shell golden harness | Not implemented | Golden-based rows, clipping regression checks |
| P7 | Reader compact breakpoint 860 reviewed against Iced fit | Provisional engineering default; no owner decision required (§3.5, §7.2) | 4B/4C composition rows (test and review, do not block) |
| P8 | Tab-strip overflow policy | **RESOLVED** by plan decision 11 (2026-09-20); implementation owned by 4B/5F | — |
| P9 | Decision-12 minimum usable column-width rule and calibration (`5A` rule, `5B` EN/JA large-font measurement) | Policy decided; numeric rule pending | FM-08…FM-12 acceptance at large book fonts |

### 1.3 Baseline pin

Pinned 2026-09-20 by the parent from `.agents/dev jj` plus a GitHub API check of
remote `main`. These are the revisions this specification refers to.

| Role | Revision | Ref / subject | Verification |
| --- | --- | --- | --- |
| **Iced reference and accepted pre-stack base** | `1e54270a6bb24f15630ece336a0575bdbe5be113` | `main@origin` — refactor(flutter): organize the frontend into Elm modules mirroring Iced (#108) | GitHub API rechecked by parent 2026-09-20; local `main` is an ancestor |
| Current application revision under repair | `f9f64204811b7c475121b8c207b9aea1613ab3da` | `fix/flutter-add-books-dialog` — #116 dialog layout fix | Differs from the base **only** in `flutter/lib/library/view_dialogs.dart` and `flutter/test/library/add_books_dialog_test.dart` (`jj diff --from 1e54270a6bb2 --to f9f64204811b --stat`: 2 files, +99/−22). Still needs 2A's keyboard/semantics repair. |
| Local `main` | `d1e06f408763d76139ebd584df7087f6051a3a69` | `main` — fix(reader): harden bookmark notes, covers, and provider import (#99) | Strictly behind the pinned base; must not be assumed equal to `main@origin` |
| Working copy (observation only) | change `txxtwkpmqtno`, commit `3b2989b56c62` at observation | `wip` | **Not a baseline.** Holds the uncommitted plan, evidence screenshots and this specification. Mutable by design; never cite as the implementation base. |

Observation, not a pin: between local `main` `d1e06f408763` and the pinned base
`1e54270a6bb2`, the 62-file change is confined to `flutter/`,
`rfd/0004/IMPLEMENTATION.org`, `Cargo.lock`, `crates/shosai-core`
(`bridge.rs`, `library.rs`, `zip_preflight.rs`, `library_tests.rs`, `Cargo.toml`) and
`crates/shosai-flutter-bridge` (`api.rs`, `frb_generated.rs`). **No file under
`crates/shosai-app` changed**, so the Iced application sources transcribed in §3 are
identical at both revisions, and the pinned base can be used as the Iced reference
without re-deriving Iced values from local `main`. Re-derive this after any rebase.

## 2. Reference configuration

### 2.1 Clients, DPR and text scale

| Code | Meaning | Use |
| --- | --- | --- |
| `W1280` | 1280×800 logical | Primary wide reference (library sidebar, reader spread) |
| `W900` | 900×700 logical | Iced default window. **Wide under both breakpoints** (900 ≥ 760 library/settings, 900 ≥ 860 reader); derived available reader width 788 → two-page spread when paginated, panels closed. Use as a wide reference, not as a compact one. |
| `C390` | 390×844 logical | Compact phone reference (library and reader compact; derived available reader width 278 → single page) |
| `D1` | DPR 1 | Default for every primary capture |
| `D2` | DPR 2 at the same logical size | Sharpness checks only, not a second composition |
| `EN` | English interface locale | Textual rows |
| `JA` | Japanese interface locale | Textual rows, wrapping and truncation |
| `MIX` | Mixed-script metadata | Latin + Japanese in one surface |
| `T200` | Flutter `TextScaler.linear(2)` | Flutter-only accessibility check on **UI text**. There is no Iced counterpart; a `T200` row is accepted on Flutter evidence only and is decoupled from EPUB book font size. |
| `BF16` | EPUB book font 16.0 logical px (Iced default), line spacing 1.6 | Baseline book-text state for pagination and spread rows |
| `BF32` | EPUB book font 32.0 logical px, line spacing 1.6 | Large-book-font check for plan decision 12 |
| `BF48` | EPUB book font 48.0 logical px (maximum), line spacing 1.6 | Large-book-font check for plan decision 12 (never shrink book text to force a spread) |
| `B760±` | Library/settings breakpoint probes: client width 759 / 760 / 761 logical (height 700, DPR 1, library or settings screen, no modal or menu open) | Compact filter row at 759, wide sidebar at 760/761. Boundary behavior without a full Cartesian sweep |
| `B860±` | Reader compact-breakpoint probes: client width 859 / 860 / 861 logical (height 700, DPR 1, reader screen, all reader panels closed) | Compact chrome at 859, wide chrome at 860/861. Page count is unaffected by this boundary: derived available width is 747/748/749, all ≥ 720, so the paginated EPUB spread persists across it |
| `B720±` | Spread-threshold probes by **derived available reader width**: panels closed, client widths 831 / 832 / 833 (height 700, DPR 1) → available 719 / 720 / 721; bookmarks open, client widths 1131 / 1132 / 1133 (height 700, DPR 1) → available 719 / 720 / 721 | Single page at 719, spread at 720/721. Client widths 831–859 also exercise compact chrome plus a spread (decision 12 will gate this by column width rather than width alone) |
| `platform` | Runs in the platform's native shell | Native picker and screen-reader checks |
| `—` | Not configuration-specific | Rows validated by unit tests or review |

Rules: primary captures are DPR 1; DPR 2 is a selected sharpness subset; `T200` is a
Flutter accessibility check with no Iced counterpart (Iced has no text scaling);
locale checks cover `EN`, `JA` and `MIX` where the row's content is textual.
`T200` and `BF*` are separate axes: `T200` scales Flutter interface text only, while
`BF*` sets EPUB book text and drives Rust pagination. A large-`T200` row may not be
used as evidence about spread columns, and a `BF48` row may not be used as evidence
about Chrome's accessibility scaling.
Boundary probes always state their client width, client height, DPR and open panels,
or a derivation from them; a bare width is not a configuration.

### 2.2 Client sizes and derived reader geometry in the Iced reference

| Fact | Value | Source |
| --- | --- | --- |
| Iced default window | 900×700 logical | `crates/shosai-app/src/main.rs:68` |
| Benchmark window | width from `SHOSAI_PERF_WIDTH`, height fixed 700 | `main.rs:62-68` |
| DPR source | `window_scale_factor`, default 1.0 | `crates/shosai-app/src/app.rs:1353`, `4265-4272` |
| PDF/CBZ raster density | `max(DPR, 2.0)` | `app.rs:4479-4482` |
| Iced text scaling | none | — |
| Compact reader chrome | client width < 860 | `app.rs:5502`, `5514-5516` |
| Compact library/settings | client width < 760 | `app.rs:6516`, `6690` |
| Available reader width | `client width − 112 (READER_HORIZONTAL_PADDING) − 300 (BOOKMARKS_PANEL_WIDTH) when the bookmarks panel is open`; floored at 1 | `app.rs:461`, `468`, `4354-4399` |
| Available reader height | `client height − 148 (READER_VERTICAL_CHROME) − 52/88 (search, wide/compact) − 62 (settings) − 58/84 (more, wide/compact)`; floored at 1 | `app.rs:462-466`, `4354-4399` |
| EPUB spread condition | paginated EPUB and available reader width ≥ 720 | `app.rs:460`, `3461-3465` |
| PDF/CBZ spread condition | paginated raster, available reader width ≥ 720 and total pages > 1 | `app.rs:4348-4352` |

Worked defaults: `W1280` panels closed → available 1168×652; `W900` panels closed →
788×552 (spread); `C390` panels closed → 278×696 (single page).
Compact breakpoint and spread threshold are independent: widths 832–859 produce
compact chrome with a two-page spread under the current width-only rule, and
decision 12 replaces that rule at large book fonts with a column-width criterion.

### 2.3 Historical captures are not a reference set

`rfd/0004/evidence/parity-review-2026-09-14/` has no manifest, mixes revisions and
sizes (one file named `1280x720` is 1600×1000), and is superseded by 1B/1C captures.
Do not cite it as evidence for any row.

## 3. Tokens

Tokens use dotted names so mapping code and tests can assert them by name. `Iced`
values are transcribed from the paths given; nothing here is a rendered measurement.

### 3.1 Application palette

Source: `crates/shosai-app/src/theme.rs`.

| Token | Value | Source line |
| --- | --- | --- |
| `app.background` | `#F4F2ED` | 4 |
| `app.surface` | `#FFFEFB` | 5 |
| `app.surfaceMuted` | `#ECE9E1` | 6 |
| `app.text` | `#282724` | 7 |
| `app.textMuted` | `#726F67` | 8 |
| `app.border` | `#D9D5CB` | 9 |
| `app.accent` | `#4D5E86` | 10 |
| `app.accentHovered` | `#3F4F76` | 11 |
| `app.accentSoft` | `#E2E6F0` | 12 |
| `app.success` | `#4E755D` | 133 |
| `app.warning` | `#A77036` | 134 |
| `app.danger` | `#A54343` | 135 |
| `app.radiusSmall` | 6.0 px | 14 |
| `app.radiusMedium` | 10.0 px | 15 |

### 3.2 Surfaces, effects and controls

Source: `crates/shosai-app/src/theme.rs` unless noted.

| Token | Value | Source line |
| --- | --- | --- |
| `app.sidebar.background` | `#EEEBE4`, no border, no radius | 157-166 |
| `app.readerHeader` | surface, border width 0 | 168-177 |
| `app.readerControls.background` | `#EEEBE4`, 1 px border | 179-187 |
| `app.readerControlGroup` | surface, 1 px border, `app.radiusMedium` | 189-197 |
| `app.tabStrip.background` | `#E7E3DA`, 1 px border | 242-249 |
| `app.tab.selected` | surface + 1 px border + `app.radiusSmall` | 252-266 |
| `app.alert.background` | `#F6E5E2` | 308-310 |
| `app.panel.background` | `#EEEBE4`, 1 px border | 312-320 |
| `app.panel.entry` | surface, 1 px border, `app.radiusMedium` | 322-330 |
| `app.skeleton` | `app.surfaceMuted`, `app.radiusSmall` | 345-352 |
| `app.skeletonSubtle` | `#E3DFD6`, radius 3.0 | 354-361 |
| `app.coverShadow` | rgba(`#21201E`, 0.16), offset (0, 4), blur 12 | 363-369 |
| `app.menu.shadow` | rgba(`#21201E`, 0.18), offset (0, 3), blur 10 | 471-484 |
| `app.modal.shadow` | rgba(`#21201E`, 0.24), offset (0, 5), blur 18 | 504-518 |
| `app.modal.backdrop` | rgba(`#21201E`, 0.42) | 500-502 |
| `app.bookHover` | `#E9E6DE` | 434-451 |
| `app.progress.background` / `.bar` | `app.surfaceMuted` / `app.accent` | 535-543 |
| `app.progress.radius` / `.girth` | 2.0 px / 4 px | `theme.rs:540`, `crates/shosai-app/src/widgets.rs:52-56` |
| `app.button.primary.padding` | [9, 14], label 14 px | `widgets.rs:6-15` |
| `app.button.secondary.padding` | [9, 14], label 14 px | `widgets.rs:17-26` |
| `app.button.navigation.padding` | [9, 12], label 14 px, fill width | `widgets.rs:28-39` |
| `app.button.book.padding` | 8 px, fill width, `app.radiusMedium` | `widgets.rs:41-50` |

### 3.3 Reader palettes

Source: `crates/shosai-app/src/theme.rs:37-124`.

| Token | Light | Dark | Sepia |
| --- | --- | --- | --- |
| `reader.background` | `#FFFFFF` | rgb(0.12, 0.12, 0.14) | rgb(0.96, 0.92, 0.84) |
| `reader.text` | rgb(0.1, 0.1, 0.1) | rgb(0.85, 0.85, 0.85) | rgb(0.3, 0.2, 0.1) |
| `reader.link` | `#174EA6` | `#8AB4F8` | `#683D00` |
| `reader.searchHighlight` | rgba(`#FFF3A3`, 0.50) | rgba(`#4C3B00`, 0.55) | rgba(`#FFE69A`, 0.45) |
| `reader.searchCurrent` | rgba(`#FFE066`, 0.45) | rgba(`#5C4500`, 0.50) | rgba(`#F4CF64`, 0.35) |
| `reader.tableHeader.background` | `#E8EEF8` | `#2B3445` | `#E5D6BA` |
| `reader.tableHeader.border` | `#596B89` | `#8797B2` | `#6B542E` |
| `reader.pageNumber.alpha` | 0.55 × text color | same | same |

Stored values are `"light"`, `"dark"`, `"sepia"`; the cycle is light → dark → sepia →
light (`theme.rs:38-52`, `117-123`). `reader.pageNumber.alpha` source:
`crates/shosai-app/src/app/epub_view.rs:370-375`.

### 3.4 Typography

| Token | Value | Source |
| --- | --- | --- |
| `type.ui.family.latin` | `Inter Variable` (bundled `InterVariable.ttf`) | `crates/shosai-app/src/typography.rs:3-8` |
| `type.ui.family.japanese` | `Noto Sans JP` (bundled `NotoSansJP-Variable.ttf`) | `typography.rs:4-8` |
| `type.ui.selection` | per-script: Japanese ranges → Noto Sans JP, else Inter | `typography.rs:10-28` |
| `type.math.family` | `Inter Variable` | `crates/shosai-core/src/epub/pagination/math_layout.rs:8-9` |
| `type.editorial.*` | Source Serif 4 / Noto Serif JP | `docs/typography.md` |
| `type.document.*` | document fonts or reader preference; never UI fonts | `docs/typography.md`, `crates/shosai-core/src/epub/native_text.rs` |

UI size scale (literal Iced sizes; count is occurrences in `crates/shosai-app/src/app.rs`):

| Token | px | Uses | Representative roles |
| --- | --- | --- | --- |
| `type.size.10` | 10 | 7 | card format/progress labels, bookmark page/delete/edit labels, review rows |
| `type.size.11` | 11 | 13 | sidebar group label, card author, bookmark note, status-bar location |
| `type.size.12` | 12 | 34 | tab labels, TOC links, search count, settings labels, zoom label, library subtitle |
| `type.size.13` | 13 | 15 | card title, error alert, reader control buttons, continue link |
| `type.size.14` | 14 | 8 | primary/secondary/navigation buttons, pick lists, cover placeholder |
| `type.size.16` | 16 | 8 | opening-document title, welcome body, settings group headings, continue-card title |
| `type.size.18` | 18 | 7 | panel and section headings |
| `type.size.20` | 20 | 5 | modal headings |
| `type.size.24` | 24 | 1 | library empty-state heading |
| `type.size.26` | 26 | 3 | page title |
| `type.size.32` | 32 | 1 | welcome title |

Semantic variants: `type.reader.title` = 15 compact / 17 wide (`app.rs:5837`);
`type.reader.edgeGlyph` = 28 compact / 36 wide (`app.rs:5678`); `type.bookmark.empty`
= 15 (`app.rs:6104`).

EPUB content type (`BF*` axis; **book text, never the interface scale**): body
`fontSize` default 16.0, step ±2.0, clamp 8.0–48.0
(`crates/shosai-app/src/app/dispatch.rs:881-901`, `app.rs:86`, `1237`); page title
`fontSize × 1.5` (`app/epub_view.rs:49`, `339`); page number 11.0
(`crates/shosai-core/src/epub/pagination.rs:18`); text line height 1.2 (ibid.:15);
line spacing default 1.6, {1.2, 1.4, 1.6, 1.8, 2.0}, clamp 1.0–2.4
(`app.rs:87`, `1238`). These sizes are document typography: changing them does not
change any Iced UI size, and Flutter `T200` does not change them.

### 3.5 Layout metrics

| Token | Value | Source |
| --- | --- | --- |
| `layout.reader.compactBreakpoint` | 860.0 logical px (compact below) — **provisional engineering default**, tested and reviewed for fit; not an owner blocker (P7) | `app.rs:5502`, `5514-5516` |
| `layout.library.compactBreakpoint` | 760.0 logical px (compact below); owner-approved starting point | `app.rs:6516`, `6690`; plan decision 9 |
| `layout.spread.minWidth` | 720.0 logical px of available reader width — **initial reference**; plan decision 12 replaces it with a Rust-owned minimum usable column width at large book fonts | `app.rs:460`, `3461-3465`, `4348-4352`; plan decision 12 |
| `layout.reader.horizontalPadding` | 112.0 | `app.rs:461` |
| `layout.reader.verticalChrome` | 148.0 | `app.rs:462` |
| `layout.reader.searchHeight` | 52.0 wide / 88.0 compact | `app.rs:463-464` |
| `layout.reader.moreHeight` | 58.0 wide / 84.0 compact | `app.rs:465-466` |
| `layout.reader.settingsHeight` | 62.0 | `app.rs:4383` |
| `layout.reader.pageGutter` | 20.0 | `app.rs:467` |
| `layout.reader.bookmarksPanelWidth` | 300.0 | `app.rs:468` |
| `layout.reader.pagePadding` | 20.0 | `app/epub_view.rs:402`, `417` |
| `layout.library.sidebarWidth` | 184.0 | `app.rs:7086` |
| `layout.library.gridMinColumn` | 220.0 (`grid(...).fluid(220)`) | `app.rs:7192` |
| `layout.library.gridSpacing` | 18.0 | `app.rs:7192` |
| `layout.library.headerSearchMaxWidth` | 380.0 | `app.rs:6566` |
| `layout.library.pageSize` | 40 books | `app.rs:425` |
| `layout.library.searchDebounce` | 200 ms | `app.rs:434` |
| `layout.import.reviewGroupRowHeight` | 28.0 | `app.rs:90` |
| `layout.import.reviewBookRowHeight` | 58.0 | `app.rs:91` |
| `layout.import.reviewOverscan` | 180.0 | `app.rs:92` |
| `layout.import.reviewDefaultViewportHeight` | 420.0 | `app.rs:93` |
| `layout.import.modalMaxWidth` | 680.0; review max height 760.0 | `app.rs:7810-7813` |
| `layout.settings.contentMaxWidth` | 760.0, padding [24, 28] | `app.rs:6895-6899` |
| `layout.modal.maxWidth.removeBook` | 440.0 | `app.rs:7851` |
| `layout.modal.maxWidth.moveLibrary` | 520.0 | `app.rs:7345` |
| `layout.continueCard.maxWidth` | 620.0 | `app.rs:8090` |
| `layout.cover.decodeBounds` | 440×420 px, source ≤ 8192 | `app.rs:426-428` |

Reader chrome spacing details (padding [vertical, horizontal] unless noted):
tab strip spacing 3 / padding [5, 10] (`app.rs:5689`); header padding [8, 14],
spacing 6 compact / 14 wide (`app.rs:5842-5845`); control button padding [7, 10]
(`app.rs:5858`); settings row padding [7, 12] (`app.rs:5944`); more panel padding
[7, 12] (`app.rs:6025`); search bar padding [8, 12] (`app.rs:6271`); status bar
padding [7, 12] with progress fixed at 280 wide (`app.rs:5784-5790`); bookmarks panel
padding 14 (`app.rs:6045`); library collection padding [22, 24] (`app.rs:7247`);
sidebar padding [22, 14] (`app.rs:7082`); library header padding [16, 20]
(`app.rs:6629`).

### 3.6 Layout math

| Rule | Value | Source |
| --- | --- | --- |
| EPUB page text width | `((available - gutter·(pages-1))/pages − 40).max(120)`, capped by `fontSize·0.55·72` | `pagination.rs:170-186` |
| EPUB page height | `(available − 40 − footer).max(120)`, `footer = 11·1.2 + fontSize·lineSpacing` | `pagination.rs:181-185` |
| EPUB spread pairing | `start = min(page, pageCount−1)`, then `start − start mod 2` when spread; visible `start ..= min(start+1, pageCount−1)` | `crates/shosai-core/src/epub/pagination.rs:188-191`, `616-627` |
| PDF/CBZ spread pairing | `start = page − page mod 2` (unclamped by the caller's page); visible `start ..= (start+1).min(total_pages−1)`; spread requires `total_pages > 1` | `crates/shosai-app/src/pdf.rs:7-21`, `app.rs:4348-4352` |
| Odd page counts | In an odd total the last index is itself even, so it is its own spread start: `start = last`, `min(start+1, last)` = `last`, and the final spread shows exactly one page. The last page is never repeated and no blank page is inserted (EPUB); the same clamp applies to PDF/CBZ | `pagination.rs:616-627`; test `pagination.rs:8567-8571` (`visible_pages(0,3,true) == [0,1]`, `visible_pages(2,3,true) == [2]`), `app.rs:16383` (`vec![2]`); `pdf.rs:82` (`visible_pages(5,3,true) == [2,3]`) |
| Zero-page documents | `visible_pages` returns an empty list before any pairing math (`page_count == 0`); `spread_start` clamps to 0. No spread is formed and no page is rendered | `pagination.rs:616-627`; `pdf.rs:11-21` |
| Single-page spread slot (odd final spread) | When spread mode is active and exactly one page is visible, EPUB appends a filler `Space` with `FillPortion(1)`, so that page keeps half the row; raster paginated views center it (`(_, 1) => Center`) | `app/epub_view.rs:412-414`, `app.rs:6473-6479` |
| Narrow single-page mode | Below the spread threshold `epub_uses_spread` is false: `visible_pages` yields exactly one page and the filler branch is not reached, so the page uses the full row (no reserved second slot) | `app.rs:3461-3465`; `app/epub_view.rs:325-334`, `412-414` |
| Decision 12 fallback | Rust chooses one page when two columns would be narrower than the minimum usable column width, preserving book font size; it restores two pages when space permits. Threshold is a `5A` rule calibrated in `5B` | plan decision 12 |
| EPUB continuous | `column` spacing 32, padding 20; width `((window − panel).min(800) − 40).max(120)` | `app/epub_view.rs:38`, `150-157` |
| PDF/CBZ continuous | `column` spacing 20, padding 20 | `app.rs:6306` |
| Fit page | `widthScale.min(heightScale)`, clamp 0.1–5.0 | `pdf.rs:23-45` |
| Manual zoom step | `clamp(0.25, 5.0)` | `app.rs:4484-4493` |
| Spread slot width | `max((available − gutters)/pages, renderedWidth)` | `pdf.rs:47-56` |

### 3.7 Persistence defaults and precedence

| Key / setting | Default | Range or options | Source |
| --- | --- | --- | --- |
| `language` | `system` | `system`, `en-US`, `ja` | `app.rs:82`, `crates/shosai-app/src/i18n.rs:20-44` |
| `library.add_behavior` | ask | ask, copy, current location | `app.rs:83`, `6940-6965` |
| `reader.default_mode` | paginated | paginated, continuous | `app.rs:84`, `1241` |
| `reader.default_theme` | light | light, dark, sepia | `app.rs:85`, `theme.rs:19-24` |
| `reader.default_epub_font_size` | 16.0 | step ±2.0, clamp 8.0–48.0 | `app.rs:86`, `1237`, `dispatch.rs:881-901`, `1826-1848` |
| `reader.default_epub_line_spacing` | 1.6 | {1.2, 1.4, 1.6, 1.8, 2.0}, clamp 1.0–2.4 | `app.rs:87`, `1238`, `6996-7013` |
| `reader.default_pdf_zoom` | fit page | fit page, fit width | `app.rs:88`, `7020-7043` |
| Per-book override | reader override flag wins over the default for the open tab | — | `app.rs:1418-1428`, `2475-2476` |
| Window geometry | `window.width`, `window.height`, `window.x`, `window.y` | — | `app.rs:469-472` |

## 4. Acceptance matrix

Each row is a draft specification. Column meanings:

- **Authority** — `Iced`, `Retained Flutter`, `RFD 6`, `Owner` or `Plan contract` (§1.1).
- **Source evidence** — code path and line establishing the current value/behavior.
- **Expected evidence** — deliverables that must exist before acceptance; codes are
  defined in §5.4. `WT` means behavioral test coverage.
- **Config** — codes from §2.1.
- **Fixture** — `F#` for existing fixtures, `G#` for an explicit gap (§5.1, §5.3).
- **Accepting package** — the package that runs the checks and owns the row's
  completion. A package never accepts a row on another package's evidence.

### 4.0 Evidence rules (apply to every row)

1. **Iced defines the target; it never establishes Flutter correctness.** An
  `1B-*`/`1C-*` capture is the reference for what to build. It does not verify the
  rebuilt Flutter surface.
2. **Every visual accepting package renders and inspects its own matched states.**
  Even where a row's Expected evidence names only `1B-*` or `1C-*` reference
  families, the accepting package must additionally produce, inspect and record its
  own Flutter renders at the same states, sizes and locales, plus behavior checks for
  interactive rows. Tests alone do not verify appearance; inspection alone does not
  verify behavior.
3. **Behavioral and visual evidence are separate requirements.** `WT` covers
  interactions, state transitions and geometry; rendered inspection covers
  composition, clipping, palette and typography. Rows whose column lists both need
  both.
4. **Where a row exists only in Flutter or in the plan** (`T200` UI scaling, CBZ
  filter entries, tiled raster seams, decision-12 fallbacks, decision-11 overflow),
  the Flutter/renderer render is the *only* acceptance evidence and the Iced capture,
  if any, is comparison-only.
5. **Reuse requires a coverage check.** A 2B golden, 2C palette render or 6C
  acceptance run may serve several rows, but the accepting package must confirm the
  row's specific state is covered rather than assuming it from a family name.
6. **Explicit later rechecks do not gate.** Evidence labelled "later recheck" or
  "cross-package recheck" is traceability, not a prerequisite for the accepting
  package. Reference captures and local acceptance evidence remain required wherever
  listed; punctuation does not change their ownership or dependency. The accepting
  package must be able to accept the row without a downstream package completing.

### 4.1 Library

Library rows are accepted by 3A–3D, which inspect their own Flutter renders of the
row's state (via the 2B harness or targeted widget renders) in addition to the
behavior checks listed; `1B-LIB-*` captures are the Iced reference, not the
acceptance.

| ID | State / behavior | Authority | Source evidence | Expected evidence | Config | Fixture | Accepting package |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LB-01 | Wide composition: header, sidebar left, collection right, 184 px sidebar | Iced | `app.rs:6515-6535`, `7045-7090` | `1B-LIB-WIDE` | `W1280` `EN` | `G1` | 3A |
| LB-02 | Compact composition: header, filter row, collection; no drawer | Owner | plan decision 9; `app.rs:6520-6524`, `7092-7127` | `1B-LIB-COMPACT` + `WT` | `C390` `B760±` `EN` | `G1` | 3A |
| LB-03 | Breakpoint: layout switches at 760; no clipped or duplicated controls at either side | Owner | `app.rs:6516`; plan decision 9 | `1B-LIB-WIDE` + `1B-LIB-COMPACT` | `B760±` `EN` `JA` | `G1` | 3A |
| LB-04 | Sidebar: `collection` label, All/EPUB/PDF entries and Settings pinned at bottom (Iced); CBZ entry is a **retained Flutter extension** | Iced (base) + Owner (CBZ) | `app.rs:7045-7090` (All/EPUB/PDF, Settings bottom); CBZ only in `flutter/lib/library/view.dart:569-585`; plan decision 9 | `1B-LIB-WIDE` (Iced base) + `WT` (CBZ + Settings behavior) | `W1280` `EN` `JA` | `G1` | 3A |
| LB-05 | Compact filter row: All/EPUB/PDF/CBZ and directly accessible Settings, no drawer | Owner + Retained Flutter | plan decision 9; Iced compact row has All/EPUB/PDF/Settings (`app.rs:7092-7127`); CBZ only in `flutter/lib/library/view.dart:569-585` | `1B-LIB-COMPACT` (Iced row shape) + `WT` (CBZ entry, Settings access, 200% text) | `C390` `EN` `JA` `T200` | `G1` | 3A |
| LB-06 | Selected filter state is visually distinct and exclusive (one format at a time) | Iced | `app.rs:7051-7071`; `theme.rs:412-432` | `1B-LIB-WIDE` | `W1280` `EN` | `G1` | 3A |
| LB-07 | Header: 26 px title, 12 px subtitle, search constrained to 380 px, add-books action; action becomes cancel with progress during import | Iced | `app.rs:6558-6650` | `1B-LIB-WIDE` | `W1280` `EN` `JA` | `G1` | 3A |
| LB-08 | Search: 200 ms debounce; empty query vs no matches are distinguishable; search and format filter combine | Iced | `app.rs:434`, `7134-7148`, `1470-1479` | `1B-LIB-STATE` | `W1280` `EN` `JA` | `G1` | 3D |
| LB-09 | Keyboard: sidebar/filter row reachable in order, Enter/Space activate, focus visible | Retained Flutter | plan decision 1; `flutter/lib/library/view.dart:569-585` | `WT` | `W1280` `C390` `T200` | `G1` | 3A |
| LB-10 | 200% text: JA and EN labels wrap or truncate without clipping or losing Settings | Retained Flutter | plan decisions 1, 9 | `WT` (3A local) — rechecked by `6C-A11Y` at XA-06 | `C390` `JA` `T200` | `G1` | 3A |
| LB-11 | Grid: `fluid(220)` columns, 18 px spacing; card shows cover, 13 px title, 11 px author, 10 px format and progress | Iced | `app.rs:7192`, `7928-8046` | `1B-LIB-WIDE` | `W1280` `EN` `JA` | `G1` | 3B |
| LB-12 | Missing cover: placeholder with title text, cover box keeps its 210 px height | Iced | `app.rs:8095-8130` | `1B-LIB-META` | `W1280` `C390` | `G1` | 3B |
| LB-13 | Long metadata: JA titles/authors wrap or truncate inside fixed title/author heights | Iced | `app.rs:8021-8022`; plan 3B | `1B-LIB-META` | `W1280` `C390` `JA` `MIX` | `G3` | 3B |
| LB-14 | Card actions: open by activation; `•••` menu with remove; removal pending state | Iced | `app.rs:7956-8046` | `1B-LIB-STATE` | `W1280` `EN` | `G1` | 3B |
| LB-15 | Covers load lazily when visible and survive paging | Retained Flutter | `app.rs:8038-8045` | `WT` | `W1280` `D2` | `G1` | 3B |
| LB-16 | Continue-reading: first read book with progress < 1.0; card shows 16 px title, 12 px author, 11 px percent, progress bar | Iced | `app.rs:7856-7866`, `8048-8093` | `1B-LIB-WIDE` | `W1280` `EN` | `G1` | 3C |
| LB-17 | Skeleton: 8 placeholder cards while the first page loads | Iced | `app.rs:7868-7922` | `1B-LIB-STATE` | `W1280` | `G1` | 3C |
| LB-18 | Empty library: heading, description, add-first-books action | Iced | `app.rs:7134-7185` | `1B-LIB-STATE` | `W1280` `C390` | `G1` | 3C |
| LB-19 | Filtered empty: distinct heading/message from empty library | Iced | `app.rs:7135`, `7144-7156` | `1B-LIB-STATE` | `W1280` `EN` | `G1` | 3C |
| LB-20 | Load error and storage error: alert bar with 13 px text, library remains usable | Iced | `app.rs:7195-7206`, `7138-7143` | `1B-LIB-STATE` | `W1280` | `G6` | 3C |
| LB-21 | Cleanup/deletion debt stays visible and retryable | Retained Flutter | `flutter/lib/library/view.dart:611-620`; plan 2D policy | `WT` | `W1280` | `G1` | 3C |
| LB-22 | Paging: previous/next appear only when applicable; loading-more indicator | Iced | `app.rs:7222-7245` | `1B-LIB-STATE` | `W1280` | `G1` | 3D |
| LB-23 | Palette states: library renders under the mapped light/dark theme with no literal theme colors | Iced + Owner | `app.rs` theme usage; plan decision 2; `flutter/lib/app_theme.dart` | `2C-PALETTE` | `W1280` | `G1` | 2C |

### 4.2 Reader chrome and panels

Reader rows are accepted by 4B–4D, which inspect their own Flutter renders at the
row's config (`4B-RENDER` or the package's own fixture renders) as well as running
the behavior checks; `1C-*` captures are the Iced reference.

| ID | State / behavior | Authority | Source evidence | Expected evidence | Config | Fixture | Accepting package |
| --- | --- | --- | --- | --- | --- | --- | --- |
| RD-01 | Wide header: back action, centered title (17 px, truncated at 58 chars), Contents/`Aa`/`⋯` actions, 14 px spacing | Iced | `app.rs:5805-5849`, `5731-5742` | `1C-RD-CHROME` | `W1280` `EN` `JA` | `F1` | 4B |
| RD-02 | Compact header: title 15 px truncated at 24 chars, 6 px spacing, actions remain reachable | Iced (normal UI scale) + Retained Flutter (200% text) | `app.rs:5807`, `5837-5842`; plan decision 1 for accessibility scaling | `1C-RD-CHROME` (Iced base, normal scale — comparison only) + `4B-RENDER` (inspected Flutter renders at normal and 200% text) + `WT` (truncation and reachable actions) | `C390` `JA` | `F1` | 4B |
| RD-03 | Tab strip: selected tab surface + border; label 12 px truncated at 34; close control present | Iced | `app.rs:5688-5729`; `theme.rs:242-286` | `1C-RD-CHROME` | `W1280` `JA` | `F1` | 4B |
| RD-04 | Tab overflow: one horizontally scrollable strip with readable tab widths; active tab revealed automatically; every tab keyboard-accessible and closable; same behavior compact | Owner | plan decision 11; Iced supplies only the scrollable strip (`scrollable(tabs).direction(Horizontal)`, hidden scrollbar, `app.rs:5722-5726`) with **no automatic active-tab reveal**, no keyboard close and no readable-width floor — those are owner-decided Flutter requirements with no Iced implementation | `WT` (scroll, reveal, keyboard/close) + `4B-RENDER` (strip at overflow, wide and compact, *not* accepted on an Iced capture) | `W900` `C390` `JA` `T200` | `G2` | 4B |
| RD-05 | Progress: 280 px bar, 11 px status text; single page vs page range wording | Iced | `app.rs:5744-5795` | `1C-RD-CHROME` | `W1280` | `F1` | 4B |
| RD-06 | Edge navigation: enabled/disabled/hover states; glyph 28 compact / 36 wide; disabled pages show no action | Iced | `app.rs:5641-5686`, `5650-5659`; `theme.rs:228-240` | `1C-RD-CHROME` | `W1280` `C390` | `F1` | 4B |
| RD-07 | Contents: heading/subheading, TOC with 12 px per-level indent, 12 px entries truncated at 38, chapter fallback numbering | Iced | `app.rs:6032-6088` | `1C-RD-PANEL` | `W1280` `JA` | `F4` | 4C |
| RD-08 | Saved places: empty state, entry with page label, note display/edit/delete, Markdown export action | Iced | `app.rs:6100-6214` | `1C-RD-PANEL` | `W1280` `EN` | `F1` | 4C |
| RD-09 | Typography controls: EPUB `A−`/`A+` with px label and theme cycle; PDF/CBZ zoom ±, fit width/page | Iced | `app.rs:5862-5948`, `5877-5921` | `1C-RD-PANEL` | `W1280` `EN` | `F1` `F2` | 4C |
| RD-10 | More panel: page input + `of N`, bookmark toggle, open book, search toggle; compact stacks vertically | Iced | `app.rs:5966-6030` | `1C-RD-PANEL` | `W1280` `C390` | `F1` | 4C |
| RD-11 | Search bar: input, `n / total`, previous/next, close; wide input capped at 420 | Iced | `app.rs:6223-6276` | `1C-RD-PANEL` | `W1280` `C390` | `F1` | 4C |
| RD-12 | Selection actions and annotation menus preserved, keyboard equivalents present | RFD 6 | `flutter/lib/reader/view_selection.dart`; plan decision 8 | `WT` + `1C` non-Iced authority record | `W1280` `C390` `T200` | `F4` | 4D |
| RD-13 | Panels are mutually exclusive (settings, more, bookmarks) | Iced | `app.rs:8510-8531` | `WT` | `W1280` | `F1` | 4B |
| RD-14 | Keyboard: all reader controls reachable; Enter/Space activate; focus visible | Retained Flutter | plan decision 1 | `WT` | `W1280` `C390` `T200` | `F1` | 4B |
| RD-15 | Large text, compact and palette renders inspected for chrome and panels | Retained Flutter | plan 4D acceptance | `WT` + fixture renders (4D local evidence) — cross-package recheck at XA-06 in 6C | `C390` `JA` `T200` `D2` | `F1` | 4D |
| RD-16 | Document opening state: 140×200 cover, 16 px title, 13 px label, max width 320 | Iced | `app.rs:5600-5639` | `1C-RD-CHROME` | `W900` | `G6` | 4B |
| RD-17 | Reader failure states: open error with locate/remove actions; missing file alert | Iced | `app.rs:5557-5590`, `5566-5583` | `1C-RD-CHROME` | `W900` | `G6` | 4B |

### 4.3 Format and mode coverage

All six combinations are required; paginated-first is an interim sequence only.

| ID | State / behavior | Authority | Source evidence | Expected evidence | Config | Fixture | Accepting package |
| --- | --- | --- | --- | --- | --- | --- | --- |
| FM-01 | EPUB paginated: styled text, headings, lists, quotes, links, page number | Iced | `app/epub_view.rs:320-425`; `pagination.rs` | `1C-EPUB-PAG` | `W1280` `EN` `JA` | `F4` | 5G |
| FM-02 | PDF paginated: raster page, page label, fit modes | Iced | `app.rs:6386-6472` | `1C-PDF-PAG` | `W1280` `EN` | `F2` | 5G |
| FM-03 | CBZ paginated: raster page with natural page sizes | Iced | `app.rs:6386-6472`; `crates/shosai-core/src/cbz.rs` | `1C-CBZ-PAG` | `W1280` | `F3` | 5G |
| FM-04 | EPUB continuous: chapter column, 32 px spacing, 20 px padding, no page boxes/titles/footers | Iced | `app/epub_view.rs:31-148`; plan continuous requirements | `1C-EPUB-CONT` | `W1280` `JA` | `F4` `F9` | 5H |
| FM-05 | PDF continuous: page column with 20 px spacing and page labels | Iced | `app.rs:6301-6378` | `1C-PDF-CONT` | `W1280` | `F2` `G4` | 5H |
| FM-06 | CBZ continuous: same column behavior as PDF | Iced | `app.rs:6305-6378` | `1C-CBZ-CONT` | `W1280` | `F3` `G4` | 5H |
| FM-07 | **EPUB spread (required):** wide paginated view shows two distinct consecutive pages side by side | Owner + Iced | plan decisions 7, 12; `app.rs:3461-3465`; `app/epub_view.rs:325-414` | `1C-SPREAD` (Iced reference) + `5H-RENDER` (inspected Flutter renders, EN and JA) | `W1280` `EN` `JA` `BF16` | `F4` | 5H |
| FM-08 | Narrow single-page mode: below the spread threshold, one page fills the row with **no reserved second slot**; in spread mode the odd final spread keeps one page plus the intentional half-width filler (§3.6) | Iced (width rule) + Owner (decision 12 fallback) | `app.rs:3464`; `app/epub_view.rs:412-414`; §3.6 "Narrow single-page mode" and "Single-page spread slot"; plan decision 12 | `1C-SPREAD` (Iced width boundary, comparison) + `5H-RENDER` (inspected Flutter renders of narrow mode, odd final spread and the fallback) + `WT` (fallback rule) | `C390` `B720±` `BF48` | `F4` `G9` | 5H |
| FM-09 | Spread threshold boundary: derived available width 719/720/721 changes page count once, without reflow artifacts | Iced | `app.rs:460`, `3464` | `1C-SPREAD` | `B720±` `BF16` | `F4` `G9` | 5H |
| FM-10 | First spread, last spread and odd page count: no orphaned blank page, correct pairing; an odd total ends with a **single-page** final spread (last page shown once, never repeated), keeping the intentional half-width slot | Iced | `pagination.rs:188-191`, `616-627`; tests `pagination.rs:8567-8571`, `app.rs:16383` | `1C-SPREAD` (Iced reference) + `5H-RENDER` (inspected Flutter renders of first, last and odd-final spreads) | `W1280` `BF16` | `F4` | 5H |
| FM-11 | Large book font: the chosen font size is preserved, two columns are replaced by one when they would be too narrow, and two columns return when space permits (never shrink book text to force a spread) | Owner (decision 12) + Plan contract | plan decision 12; Rust owns the layout choice (5A rule, 5B calibration). **No Iced counterpart**: Iced applies a width-only 720 rule and never falls back for readability, so an Iced capture at large fonts is comparison only and cannot evidence this row | `5H-RENDER` (inspected Flutter/renderer renders at 32 px and 48 px book font, **EN and JA**) + `WT` (5A rule and 5B measured calibration) | `W1280` `EN` `JA` `BF32` `BF48` | `F4` `G3` `G9` | 5H |
| FM-12 | Width transition preserves the durable location across single/spread layouts, including the decision-12 fallback boundary | Iced (location preservation) + Owner (fallback boundary) | `app.rs:3483-3506`, `epub_layout_key`; plan decision 12 | `WT` + `5H-RENDER` (inspected renders at both sides of the boundary) + `1C-SPREAD` (Iced reference for the wide layout) | `B720±` `W1280` `BF32` `BF48` | `F4` `G9` | 5H |
| FM-13 | PDF/CBZ spread plus typed fit page/fit width/manual; pairing and inner-edge alignment | Iced | `app.rs:4348-4352`, `6413-6480`; `pdf.rs:7-21` | `1C-SPREAD` | `W1280` | `F2` `F3` | 5H |
| FM-14 | Continuous seam: cuts through text, images and block spacing show no gap, duplicate, artificial background band or cumulative drift, verified against an untiled render | Plan contract | plan continuous requirements; Iced continuous is a single chapter column (`app/epub_view.rs:31-148`) and has **no tiled render**, so Iced screenshots cannot evidence tile seams | `5H-RENDER` (inspected tile-versus-untiled renders, DPR 1 and 2) + `WT`; re-measured in 5J | `W1280` `D2` | `G5` | 5H (5J re-measure) |
| FM-15 | Mode switch preserves position and does not rebuild durable state from page indices | Iced | plan contract requirements | `WT` | `W1280` | `F4` | 5H |
| FM-16 | EPUB selection may cross visual fragments within one spine item and clamps at its boundary | RFD 6 | `rfd/0006/README.adoc`; plan decision 8 | `WT` + RFD 6 tests | `W1280` | `F4` | 5I |
| FM-17 | PDF selection stays within one page | RFD 6 | `rfd/0006/README.adoc`; plan decision 8 | `WT` + RFD 6 tests | `W1280` | `F2` | 5I |
| FM-18 | EPUB pages keep document colors; no monochrome tinting of composited RGBA pages | Iced | plan 5G acceptance | `1C-EPUB-PAG` | `W1280` | `F4` `F7` | 5G |
| FM-19 | DPR 2 sharpness: text and images remain crisp at raster scale, no blur or double-scaling | Retained Flutter | plan 6C; `app.rs:4479-4482` | `6C-A11Y` | `D2` | `G7` | 6C |
| FM-20 | Resource rejection is distinguishable from a rendering defect | Iced | `pagination.rs` limits; plan 5J | `WT` | `W1280` | `F10` | 5J |
| FM-21 | Bidi and mixed-script composition (Hebrew, Arabic, Japanese, Latin) preserves logical order and shaping | Iced | `crates/shosai-core/src/epub/native_text.rs`; `epub-conformance/generate.py:100-105` | `1C-EPUB-PAG` | `W1280` `MIX` | `F5` | 5C |
| FM-22 | Embedded document fonts stay isolated from interface fonts and fall back cleanly when corrupt | Iced | `crates/shosai-core/src/epub/native_text.rs`; `docs/typography.md` | `1C-EPUB-PAG` | `W1280` `EN` | `F8` | 5C |
| FM-23 | Tables and inline/display math compose within the page budget; fallback text maps to canonical text | Iced | `crates/shosai-core/src/epub/pagination.rs` table/math layout; `app/epub_view.rs` rendering | `1C-EPUB-PAG` | `W1280` `EN` | `F6` `F7` | 5D |

### 4.4 Import workflow

| ID | State / behavior | Authority | Source evidence | Expected evidence | Config | Fixture | Accepting package |
| --- | --- | --- | --- | --- | --- | --- | --- |
| IM-01 | Entry: heading, description, choose-files and choose-folder actions, cancel | Iced | `app.rs:7783-7805` | `1B-IMPORT` (Iced reference) + `6A-RENDER` (inspected Flutter renders, EN and JA) + `WT` | `W900` `EN` `JA` | `G1` | 6A |
| IM-02 | Native pickers retained per platform; Android provider documents copied then released | Retained Flutter | `flutter/lib/library/view.dart:171-270`; `flutter/lib/android_document_import_adapter.dart` | `WT` + the 2B bounded native smoke runner (6A local) — full pass rechecked by `6C-NATIVE` | platform | `G1` | 6A |
| IM-03 | Discovery progress: enumerating / reading / checking phases with counts, progress bar, back and cancel | Iced | `app.rs:7467-7532`, `7432-7443` | `1B-IMPORT` + `6A-RENDER` (each phase) + `WT` | `W900` `JA` | `G1` | 6A |
| IM-04 | Review list: group headers, checkbox rows with format badge and size, select-all-new, filter, no-supported vs no-matching empty states | Iced | `app.rs:7533-7761`, `7378-7404` | `1B-IMPORT` + `6A-RENDER` (both empty states and a mixed selection) + `WT` | `W900` `JA` | `G1` | 6A |
| IM-05 | Duplicates: already-in-library and duplicate-selected-file are labeled per row and excluded from select-all-new | Iced | `app.rs:7544-7549`, `7602-7626` | `1B-IMPORT` + `6A-RENDER` (duplicate labels) + `WT` | `W900` `EN` | `G1` | 6A |
| IM-06 | Discovery failures are surfaced with count, file and reason | Iced | `app.rs:7639-7662` | `1B-IMPORT` + `6A-RENDER` (failure state) + `WT` | `W900` | `G1` | 6A |
| IM-07 | Storage choice: copy-into-library vs use-current-location with descriptions; choice changeable before import | Iced | `app.rs:7664-7708` | `1B-IMPORT` + `6A-RENDER` (both choices) + `WT` | `W900` `EN` `JA` | `G1` | 6A |
| IM-08 | Import in progress: per-book progress, cancel, and library stays consistent afterwards | Iced + Retained Flutter | `app.rs:7710-7711`; `flutter/lib/library/controller.dart` import path | `1B-IMPORT` + `6A-RENDER` (in-progress and post-import) + `WT` | `W900` | `G1` | 6A |
| IM-09 | Completion: imported/failed/cancelled summary; partial failures remain visible and actionable | Retained Flutter | `flutter/lib/library/controller.dart`; plan 2D policy | `6A-RENDER` (each outcome) + `WT` | `W900` | `G1` | 6A |
| IM-10 | Modal layout: max width 680; review state fills height to a 760 maximum; backdrop dismiss | Iced | `app.rs:7807-7816`, `7253-7273` | `1B-IMPORT` + `6A-RENDER` (wide and compact) + `WT` | `W900` `C390` | `G1` | 6A |
| IM-11 | Dialog accessibility: focus lands in the dialog, Enter/Space activate both choices, semantics expose buttons | Retained Flutter | plan 2A acceptance; `flutter/test/library/add_books_dialog_test.dart` | `WT` | `W900` `T200` | `G1` | 2A |
| IM-12 | Long file and folder names, JA paths: labels wrap or truncate without hiding the checkbox or actions | Retained Flutter | `app.rs:7590-7601`, `7365-7376` | `1B-IMPORT` (Iced reference for the label slot) + `6A-RENDER` (long JA paths, normal and 200% text) + `WT` | `W900` `JA` `T200` | `G3` | 6A |

### 4.5 Settings workflow

| ID | State / behavior | Authority | Source evidence | Expected evidence | Config | Fixture | Accepting package |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ST-01 | Language: system / English / Japanese; applying a change updates UI immediately | Iced | `app.rs:6652-6679`; `i18n.rs:28-44`, `69-79` | `1B-SETTINGS` + `6B-RENDER` (all three language states) + `WT` (includes the <100 ms language-switch expectation from [typography guidance](typography.md)) | `W900` `EN` `JA` | `G1` | 6B |
| ST-02 | Managed location: current path display, open folder, change location | Iced | `app.rs:6761-6804` | `1B-SETTINGS` + `6B-RENDER` (long JA path) + `WT` | `W900` `JA` | `G1` | 6B |
| ST-03 | Move library: from/to paths, book count and size summary, confirm/cancel, in-progress disabled, error retained | Iced | `app.rs:7275-7348`, `7285-7291` | `1B-SETTINGS` (dialog form) + `6B-RENDER` (form, in-progress, error) + `WT` | `W900` | `G1` | 6B |
| ST-04 | Import behavior: ask / copy / current location, persisted and used by the next import | Iced | `app.rs:6940-6965`; `library.add_behavior` | `1B-SETTINGS` + `6B-RENDER` (three options) + `WT` | `W900` `EN` `JA` | `G1` | 6B |
| ST-05 | Reader defaults: reading mode, theme, EPUB font size (8–48, step 2), line spacing (1.2–2.0), PDF zoom fit page/width | Iced | `app.rs:6806-6872`, `6968-7043` | `1B-SETTINGS` + `6B-RENDER` (each control) + `WT` | `W900` `EN` | `G1` | 6B |
| ST-06 | Settings error banner: 12 px text on the alert surface, remains visible until resolved | Iced | `app.rs:6886-6893` | `6B-RENDER` (error banner) + `WT` | `W900` | `G6` | 6B |
| ST-07 | Unavailable/disabled states: library actions disabled while moving, importing or removing; unavailable path shown when no library | Iced | `app.rs:6766-6769`, `7292-7308` | `1B-SETTINGS` + `6B-RENDER` (disabled and unavailable states) + `WT` | `W900` | `G1` | 6B |
| ST-08 | Persistence and precedence: defaults persist across restart; per-book override wins for the open tab | Iced | `app.rs:1418-1428`, `2533-2599` | `WT` | `W900` | `G1` | 6B |
| ST-09 | Settings layout: 760 breakpoint, content max width 760 with [24, 28] padding, stacked controls when compact | Iced | `app.rs:6689-6703`, `6895-6899`, `6922-6938` | `1B-SETTINGS` + `6B-RENDER` (wide, compact, 200% text) + `WT` + `2C-PALETTE` | `W900` `C390` `JA` `T200` | `G1` | 6B |
| ST-10 | Full capability parity: every Iced settings and import capability is present or has a new explicit owner decision | Owner | plan decision 10 | review record | — | — | 6B, 6A |

### 4.6 Notice and feedback policy (decision 13)

Owner-approved policy; 2D implements and tests it, and 6A/6B verify it in the
completed workflows. Today `flutter/lib/library/view.dart:601-660` renders persistent
`LibraryBanner` rows and there is no toast layer in the retained tree; #110 is the
retained notice infrastructure per the plan.

| ID | State / behavior | Authority | Source evidence | Expected evidence | Config | Fixture | Accepting package |
| --- | --- | --- | --- | --- | --- | --- | --- |
| NT-01 | Successful import uses a brief, auto-expiring toast; the library stays usable and no modal or persistent banner remains | Owner + Retained Flutter | plan decision 13; #110 notice infrastructure | `WT` | `C390` `W900` `EN` `JA` | `G1` | 2D (re-verified in 6A) |
| NT-02 | Successful settings save and successful copy action use a brief toast | Owner | plan decision 13 | `WT` | `W900` `EN` `JA` | `G1` | 2D (settings re-verified in 6B) |
| NT-03 | Failed or partial import stays visible with per-item details and applicable retry; it is never reduced to a toast | Owner | plan decision 13; plan 2D | `WT` | `C390` `W900` `JA` | `G1` | 2D (re-verified in 6A) |
| NT-04 | Failed saves, missing files, permission problems and cleanup/deletion debt stay visible with details and applicable recovery or retry actions | Owner | plan decision 13; `flutter/lib/library/view.dart:605-625` (retained debt banners) | `WT` | `W900` | `G6` | 2D (re-verified in 6B) |
| NT-05 | A correctable error inside the current dialog is shown inline in that dialog and does not also raise a toast | Owner | plan decision 13 | `WT` | `W900` `C390` | `G1` | 2D |
| NT-06 | Cancellation is neutral: no error styling, no failure copy, no red surface | Owner | plan decision 13 | `WT` | `W900` `C390` | `G1` | 2D (re-verified in 6A) |
| NT-07 | The same unresolved problem is not re-toasted; persistence and dismissal are exactly-once until the state changes | Owner | plan decision 13; plan 2D exactly-once tests | `WT` | `W900` | `G1` | 2D |
| NT-08 | End-to-end workflows obey the policy: brief success feedback, persistent actionable failures, inline dialog errors, neutral cancellation | Owner | plan decision 13 | 6A/6B verification records | `W900` `C390` `JA` | `G1` `G6` | 6A, 6B |

### 4.7 Cross-cutting acceptance

| ID | State / behavior | Authority | Source evidence | Expected evidence | Config | Fixture | Accepting package |
| --- | --- | --- | --- | --- | --- | --- | --- |
| XA-01 | Golden harness runs the production shell including `ShadAppBuilder` | Retained Flutter | `flutter/lib/main.dart:135-147`; plan 2B | `2B-GOLDEN` | `W1280` | `G1` | 2B |
| XA-02 | Deterministic fonts, data and rasters in the harness | Retained Flutter | `flutter/test/product_shell_test.dart:17-34`; plan 2B | `2B-GOLDEN` | `W1280` `D1` | `G1` | 2B |
| XA-03 | Overflow and clipping detection, including the known clipped-label fixture separately | Retained Flutter | plan 2B; historical `07-golden-clipped-tabs-3x.png` | `2B-GOLDEN` | `W900` `T200` | `G2` | 2B |
| XA-04 | Token mapping asserts values on both sides and rejects new literal theme colors | Iced | plan 2C; `flutter/lib/app_theme.dart` | `WT` | — | — | 2C |
| XA-05 | Application palette mapping inspected for library and chrome in light and dark (the library has **no sepia**; reader palettes are separate, §3.3) | Iced + Owner | plan 2C; §3.1, §3.2 | `2C-PALETTE` | `W1280` | `G1` | 2C |
| XA-06 | English, Japanese and mixed-script text at normal and 200% | Retained Flutter | plan 6C | `6C-A11Y` | `W1280` `C390` `EN` `JA` `MIX` `T200` | `G3` | 6C |
| XA-07 | Keyboard-only pass over library, reader and dialogs | Retained Flutter | plan 6C | `WT` + `6C-A11Y` | `W1280` `C390` | `G1` | 6C |
| XA-08 | Named platform screen-reader checks | Retained Flutter | plan 6C | `6C-NATIVE` | platform | `G1` | 6C |
| XA-09 | DPR 2 sharpness for text and images | Retained Flutter | plan 6C | `6C-A11Y` | `D2` | `G7` | 6C |
| XA-10 | Every capture carries a manifest entry (revision, fixture hash, fonts, size, DPR) | Owner | plan Stage 1 requirements | manifest review | — | `G8` | 1B, 1C |
| XA-11 | Reader surface inspected in all three reader palettes (light, dark, sepia) on the reader alone; the library theme is mapped separately in XA-05 | Iced | `theme.rs:54-124`; §3.3 | `2C-PALETTE` (mapping); 5G inspects the integrated reader surface under §4.0 rule 2 | `W1280` `EN` `JA` | `F1` `F4` | 2C, 5G |

## 5. Fixtures and provenance

### 5.1 Existing fixtures

Hashes are SHA-256 and were computed from the working copy on 2026-09-20.

| ID | Fixture | Size | Content | SHA-256 | Provenance status |
| --- | --- | --- | --- | --- | --- |
| `F1` | `crates/shosai-core/tests/fixtures/sample.epub` | 2,840 B | generated 2-chapter EPUB, 1 px PNG cover | `57875ecbc8b9656d3671f3384d366c89182ccff43df8ed9e5fa8f631d1b4bae6` | generated content; **no in-tree license/provenance record** |
| `F2` | `crates/shosai-core/tests/fixtures/sample.pdf` | 865 B | 2 pages, Helvetica, "Hello World" | `6bc48cb51d339b242e11ed63dd257ee45f929127fb8ecf50e85d1307bf8b614d` | generated content; no in-tree record |
| `F3` | `crates/shosai-core/tests/fixtures/sample.cbz` | 827 B | 3 tiny PNG pages, `ComicInfo.xml`, `__MACOSX/.DS_Store` | `1e184f5f978fc541757a9db748081903c6365832ba4f384da725fad0390669a5` | generated content; no in-tree record |
| `F4` | `.../epub-conformance/conformance.epub` | 16,289 B | 8 chapters: fonts, images, tables, math, links, bidi | `2f9687c08a59b36f7a27e8ae6a0e15bee672485a338bbd914caf48f2d5e4908a` | documented redistribution-safe in `epub-conformance/README.md` |
| `F5` | `.../epub-conformance/bidi.epub` | 2,492 B | Japanese, Hebrew, Arabic mixed text | `5af9e82d15fa0be324ef7e219ddfc0613cb54b9706addb161c83f188cf9b810d` | documented redistribution-safe |
| `F6` | `.../epub-conformance/table.epub` | 2,977 B | table overflow and pagination | `9f54aac1fe4026cc06eb255a9d92a57d2d5dca7c7e6e38c8bb3bada847e48409` | documented redistribution-safe |
| `F7` | `.../epub-conformance/mathml.epub` | 3,021 B | MathML cases and fallbacks | `03f1978d9ea58cabc81643e1737bed8887a3d7783e79c719ea4c72762ed0ffe6` | documented redistribution-safe |
| `F8` | `.../epub-conformance/fonts.epub` | 8,309 B | embedded font formats and corrupt fallback | `bcd605900627847c0addb541aa5f1698df4709db14321b028aff2b9d8e9962e7` | documented redistribution-safe |
| `F9` | `target/epub-perf-fixtures/large-text.epub`, `large-image.epub` (generated) | varies | 16 chapters, byte-stable generator | not committed; generated by `benchmarks/epub-page-turn/2026-08-17/generate-fixtures.py` | generated by repo script; redistribution statement not recorded |
| `F10` | `.../epub-conformance/resource-limits.epub` | 2,100,942 B | oversized repetitive font/text resources | `e330d9346fa9bf60e46db7326a9b284595ee624df229cb6bcb3fc19f94dae28a` | documented redistribution-safe |

Verification facts: `sha256sum -c SHA256SUMS` passes for all 15 conformance books.
`SHA256SUMS` itself is `df15f0003a7ef1f83d28f93e546351e7870eda096ddf08ffab7eb8fe463928f7`,
its `README.md` is `4add97d275c08a58aa1c05d8d8a0b6ccf3ca52e56222745b00cd4a650a026fbb`,
and `generate.py` is `b096774364df2741edbf92a0076e10f6e162b88a01b5d14534ecb5141a2e0081`.
The conformance set is the only fixture family with an explicit redistribution
statement; nothing else in this table may be described as redistribution-safe until a
record exists.

Bundled fonts (hashes match `assets/fonts/README.md`):
`InterVariable.ttf` `4989b125924991b90d05b2d16e0e388c48f7d5bb8b30539bbf9c755278d0ccaf`;
`NotoSansJP-Variable.ttf` `c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f`;
`SourceSerif4Variable-Roman.ttf` `14d360ee1b76655da9276628b229e11671bc1f5d1083636144db6677d452cf55`;
`NotoSerifJP-ShosaiMark-Regular.ttf` `8ecace995946627dd90e74dddaed727e66304dff9f619adc2446de78b469a9a8`.

Test-only fonts under `crates/shosai-app/tests/fonts/` have licenses but no recorded
source/version: `InterVariable-Italic.ttf`
`d6f1f6a172d9e588438db9f986fd5cfad7b30f644374080a8a9d4d91e344586f`,
`NotoSansArabic.ttf` `ee489b994b3e62def9874c918145e32b133b625abaf98cec60502bdb40102c56`,
`NotoSansHebrew.ttf` `3d4fef85b449ade4d165de982969374fa30b2a5fe7bc679f5a3f5bfc047fb703`,
plus generated `epub/book-a.{ttf,otf,woff,woff2}`, `book-b.ttf`, `other-family.ttf`
(generator `dcf135e196e627293fb871e1782b6e3ab3a5dedf394578140d363bc688169bb5`).

### 5.2 Provenance (separately owned; citation rule here)

The [fixture provenance record](../crates/shosai-core/tests/fixtures/README.md)
documents the completed research: F1–F3 hashes and adding commits are verified, but
their authoring tools and exact origins remain unknown. `sample.pdf` also has
incorrect xref offsets and relies on reader recovery. Research completion is not
provenance approval. Keep these existing regression fixtures unchanged; 1B/1C must
produce documented reference fixtures for affected captures and record the actual
fixture/hash used against each row. F1–F3 remain inventory references, not approved
capture assets. Shared fixture generation has one owner under 1B, reused by 1C.

The record also verifies that the conformance EPUB fonts come from the repository's
rectangle-glyph generator, not the separately sourced test fonts. The EPUB archives
regenerate byte-identically; regeneration of their input fonts with the pinned
toolchain remains a 2C follow-up. That follow-up is distinct from establishing the
fonts' generated origin.

The citation rule this document needs is narrow: a fixture may be cited in a row only
when its SHA-256 recomputes and its record names a generator or documented source.
Otherwise cite it as **unverified provenance** and keep the row's acceptance open on
provenance. Only the conformance family carries an explicit redistribution statement
today (`crates/shosai-core/tests/fixtures/epub-conformance/README.md` + `SHA256SUMS`,
verified in §5.1); no other asset may be called redistribution-safe.

### 5.3 Proposed fixture additions (not yet created)

| ID | Fixture | Purpose | Proposed generation | Rows served |
| --- | --- | --- | --- | --- |
| `G1` | Library seed profile (imported books with covers, progress, one continue-reading book, one removal-pending book) | Deterministic library captures without hand-building state | Script that imports committed fixtures into a disposable `XDG_DATA_HOME`; no database committed | LB-01…LB-22, IM-*, ST-* |
| `G2` | Many-tab and clipped-label fixtures | Tab overflow policy (decision 11) and known clipping regression | Widget-test fixture, no file | RD-04, XA-03 |
| `G3` | Long Japanese/mixed metadata set | Truncation, wrapping, 200% text | Generated EPUBs/PDFs with JA titles, authors and paths | LB-13, IM-12, XA-06 |
| `G4` | Large PDF and CBZ (many pages, mixed page sizes) | Continuous, spread pairing, paging stress | Generated deterministically; no third-party scans | FM-02/03/05/06/13 |
| `G5` | Small continuous seam fixture with text, image and block-spacing cuts | Untilied seam comparison | Generated EPUB plus an untiled reference render | FM-14 |
| `G6` | Failure-state fixtures (missing file, corrupt document, storage error, permission failure) | Reader, settings and notice failure states | Generated; documented | LB-20, RD-17, ST-06, NT-04, NT-08 |
| `G7` | DPR 2 sharpness fixture (small text plus image) | Sharpness checks | Generated | FM-19, XA-09 |
| `G8` | Capture manifest and reference baselines | Reproducible evidence set | Emitted by the 1B/1C capture runner | XA-10 |
| `G9` | Decision-12 readability set: EN and JA books at `BF16`/`BF32`/`BF48` with measured page-column widths | Calibrates the `5A` minimum usable column-width rule; verifies single↔spread transitions never shrink book text | Generated from the conformance generator (`crates/shosai-core/tests/fixtures/epub-conformance/generate.py`); measurements recorded by 5B | FM-08, FM-09, FM-11, FM-12 |

Every new fixture must record: generator path, deterministic inputs, SHA-256, whether
any third-party content is present, and an explicit redistribution statement. Until
then, no new fixture may be called redistribution-safe.

### 5.4 Evidence codes

| Code | Deliverable | Status |
| --- | --- | --- |
| `1B-LIB-WIDE`, `1B-LIB-COMPACT`, `1B-LIB-STATE`, `1B-LIB-META` | Library capture families from 1B (Iced reference) | Pending (P2, P4) |
| `1B-IMPORT`, `1B-SETTINGS` | Iced import-workflow and settings capture families from 1B (Iced reference for IM-* and ST-* rows) | Pending (P2, P4) |
| `1C-RD-CHROME`, `1C-RD-PANEL`, `1C-SPREAD` | Reader chrome, panels and spreads from 1C (Iced reference) | Pending (P2, P4) |
| `1C-EPUB-PAG`, `1C-EPUB-CONT`, `1C-PDF-PAG`, `1C-PDF-CONT`, `1C-CBZ-PAG`, `1C-CBZ-CONT` | Per-format/mode reader evidence (Iced reference) | Pending (P2, P4) |
| `1C` non-Iced authority record | RFD 6 and Flutter evidence for selection | Pending |
| `2B-GOLDEN` | Production-shell golden harness (Flutter) | Pending (P6) |
| `2C-PALETTE` | Mapped palette renders (Flutter) | Pending |
| `4B-RENDER` | 4B inspected Flutter renders: reader chrome, normal and 200% text, wide and compact | Pending |
| `5H-RENDER` | 5H inspected Flutter/renderer renders: spreads (first/last/odd-final), narrow single-page mode, decision-12 fallback at EN+JA large fonts, tile-versus-untiled seams | Pending |
| `6A-RENDER`, `6B-RENDER` | 6A/6B inspected Flutter renders of import and settings states, normal and 200% text | Pending |
| `6C-A11Y`, `6C-NATIVE` | Accessibility and native smoke acceptance | Pending |
| `WT` | Behavioral tests through rendered controls, or renderer-level tests with independent expectations. Never sufficient alone for an appearance claim (§4.0). | Existing infrastructure; rows not yet implemented |

Two limits on Iced evidence, stated so no row silently depends on a capture Iced
cannot produce: `T200` UI text scaling, CBZ filter entries, tiled raster seams,
decision-11 overflow behavior and decision-12 readability fallback have no Iced
counterpart, so their rows are satisfied by the Flutter/renderer deliverables above
rather than by `1B-*`/`1C-*` captures. Where an Iced capture is listed beside them it
is comparison only.

**Dependency rules for evidence codes.** `1B-*` and `1C-*` codes are *references*
produced in Stage 1; they feed Stage 3–6 work but never substitute for an accepting
package's own renders. `2B-GOLDEN` belongs to 2B, `2C-PALETTE` to 2C, `4B-RENDER` to
4B, `5H-RENDER` to 5H, `6A-RENDER`/`6B-RENDER` to 6A/6B, and `6C-*` to 6C; a row
whose accepting package differs from the code's owner must name both (for example
`2C-PALETTE` reviewed by 5G, or `1B-IMPORT` referenced by 6A). No row may cite as
gating evidence a code owned by a package that depends on the accepting package;
explicitly labelled later rechecks are traceability only (§4.0 rule 6).
Section 7.1 verifies this owner-versus-acceptor relationship, not just the code's
existence. Fixtures follow the same rule: a fixture is named per row as the state to
render, and its provenance status does not upgrade the row's evidence — a row cannot
be accepted on a fixture whose provenance record is still open (§5.2).

## 6. Allowed differences

| Kind | Example | Treatment |
| --- | --- | --- |
| Retained Flutter improvement | Touch targets, focus rings, native pickers, large-text support, selection/highlighting | Keep; must not regress accessibility to match Iced |
| Owner-decided extension | Automatic active-tab reveal and keyboard close (decision 11); EPUB readability fallback (decision 12) | Required new behavior, not an existing Flutter capability; implementation and verification remain open |
| Permanent toolkit difference | Text rasterization, dialog chrome, scroll physics, DPR-aware rasterization, toast presentation | Record per row; does not need to look identical |
| Temporary gap | Unimplemented spread, continuous tiles, or import/settings capability | Keeps its accepting package open; never presented as complete |
| New product exclusion | Any capability dropped or narrowed | Requires a new explicit owner decision (plan decisions 7 and 10); implementers cannot waive it |

## 7. Validation and decisions

### 7.1 Validation performed on this draft

| Check | Method | Result |
| --- | --- | --- |
| Local links resolve | Every Markdown link target resolved relative to `docs/` | All targets exist |
| Row IDs unique | Extracted all `LB-`, `RD-`, `FM-`, `IM-`, `ST-`, `NT-`, `XA-` IDs | 104 rows (LB 23, RD 17, FM 23, IM 12, ST 10, NT 8, XA 11), no duplicates |
| Prerequisite IDs | `P1`–`P9` defined once in §1.2 and referenced elsewhere | Unique definitions |
| Accepting packages valid | Compared against the 30 package IDs in the restoration plan | All exist |
| Config, fixture and evidence codes | Every code used in a matrix row checked against its definition table | No undefined or unused references |
| **Evidence-ownership dependency** | For each row, the owner package of every gating code compared against the row's accepting packages using the plan's dependency direction; later rechecks excluded per §4.0 rule 6 | No row requires evidence a package cannot produce before its own acceptance |
| **Visual coverage of IM/ST rows** | Each import/settings visual row checked for a local render deliverable alongside `WT`; `IM-02` (native picker), `IM-11` (dialog accessibility), `ST-08` (restart persistence) and `ST-10` (review record) confirmed non-visual/behavioral | All visual IM/ST rows carry `6A-RENDER`/`6B-RENDER` |
| **Non-Iced rows** | Rows whose behavior has no Iced counterpart checked for Flutter/renderer evidence and comparison-only labelling | FM-08, FM-11, FM-14, RD-02, RD-04, LB-05, XA-03 confirmed |
| Table shape | Each matrix row parsed as 8 columns; every table block column-consistent | 27 blocks, no malformed rows |
| Baseline revisions | Re-derived with `.agents/dev jj` (status, log, `jj diff --from 1e54270a6bb2 --to f9f64204811b --stat`) | Pin in §1.3 matches; #116 diff limited to its two files |
| Fixture hashes | Recomputed SHA-256 for every committed fixture cited | Matches `SHA256SUMS` for the conformance set; others recorded in §5.1 |

### 7.2 Decisions recorded and remaining engineering follow-ups

All product choices raised so far are **resolved by the owner** and are recorded in
the restoration plan; nothing in this section blocks 1A on a product question.

| Reference | Decision / follow-up | Status |
| --- | --- | --- |
| Plan decisions 7, 9, 10 | Spreads required for EPUB/PDF/CBZ, compact library navigation without a drawer, full import/settings capability | Decided; implementation in 5H, 3A, 6A/6B |
| Plan decision 11 | Tab overflow: one horizontally scrollable strip with active-tab reveal and keyboard-accessible close; no wrap or overflow menu | Decided; `RD-04`, implementation in 4B |
| Plan decision 12 | EPUB readability fallback: preserve book font size, one column when two would be too narrow, restore two when space permits; Rust owns the choice | Decided; numeric rule pending in `P9` (5A/5B), integration in 5H |
| Plan decision 13 | Notice policy: brief success toasts, persistent actionable failures, inline dialog errors, neutral cancellation, no duplicate unresolved notices | Decided; `NT-01`…`NT-08`, implementation in 2D, verification in 6A/6B |
| P7 | Reader compact breakpoint 860 as an engineering default | Provisional; 4B/4C test and review fit against Iced captures |
| P9 | Decision-12 minimum usable column width | Engineering measurement (5A rule, 5B calibration with `G9`) |
| P5, §5.2 | Fixture provenance records | Research recorded; 1B/1C own capture-fixture follow-ups, 2C owns font records. Existing regression fixtures remain unchanged. |
| 1A acceptance | Parent baseline/review checks and owner approval of the working contract | Accepted 2026-09-20 — no implementation row here is accepted evidence |

### 7.3 Recorded basis for 1A acceptance

The owner accepted this working contract on 2026-09-20 on the following basis.
Downstream deliverables remain open; accepting the inventory does not approve captures.

1. Parent confirmation that the §1.3 pin (Iced reference `1e54270a6bb2`, application
   revision `f9f64204811b`, local `main` `d1e06f408763`) is the intended recorded base.
2. Owner review of this specification as a whole, including the row set, the
   provisional 860 breakpoint and the fixture plan.
3. Confirmation that every row's authority, configuration, fixture and accepting
   package are correct, and that no row depends on evidence its package cannot produce.
4. Acknowledgement that no capture evidence exists yet; 1B and 1C remain the
   evidence-producing packages and P2–P7 and P9 remain open.
5. Review the fixture provenance record (§5.2) and its assigned follow-ups. Research
   is complete, but affected assets remain unverified and cannot support approved
   captures until 1B/1C supply documented reference fixtures. Producing those fixtures
   is downstream work, not a prerequisite for accepting this inventory.
