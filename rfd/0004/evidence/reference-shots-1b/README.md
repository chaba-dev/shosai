# 1B reference captures (Iced, package 1B)

Generated evidence for the `1B-LIB-*`, `1B-IMPORT` and `1B-SETTINGS` families of the
Flutter UI reference specification. These images are the **Iced reference**, not
acceptance evidence for the Flutter restoration: each accepting package still produces
and inspects its own renders (specification §4.0).

- Entry point: `make reference-shots`
- Command: `make reference-shots`
- Capture-code revision: `bebec1ff30197e24025808e368e7a82ae72f7eca` (from jj @ working-copy commit, Jujutsu change `nqrsuovkrqywxyswwsyrvluvxvkvttzr`, bookmark `none`)
- Revision note: `capture_code_revision` is the working-copy commit id at render time. Jujutsu rewrites a commit id when its change is described or committed, so the stable `capture_code_change_id` plus the committed evidence change is the durable mapping; `make reference-shots VERIFY=1` re-renders this evidence byte-identically at any revision that carries the change.
- Pinned design base: `1e54270a6bb24f15630ece336a0575bdbe5be113` — main@origin #108 (refactor(flutter): organize the frontend into Elm modules mirroring Iced)
- Preference baseline: `language=en-US`, `library.add_behavior=ask`, `reader.default_mode=paginated`, `reader.default_theme=light`, `reader.default_epub_font_size=16`, `reader.default_epub_line_spacing=1.6`, `reader.default_pdf_zoom=fit-page`
- Renderer: iced_tiny_skia 0.14 (software, in-process) · theme theme::application() — iced::Theme::custom(APP_BACKGROUND #F4F2ED) · default font Inter Variable (bundled InterVariable.ttf) at 16 px
- Generated: linux · x86_64 (rustc rustc 1.94.0 (4a4ef493e 2026-03-02))
- Seeded library: 46 books (`G1 library seed: 14 featured books (incl. one reused conformance book and two without covers) + 32 filler books, one continue-reading entry`), page size 40, order `last_read DESC NULLS LAST, date_added DESC, id DESC`
- Continue-reading seed: The Quiet Cartographer (library/featured/quiet-cartographer.epub) at 42%
- Captures: 56

## Files

- `captures/*.png` — one image per capture; `captures.sha256` verifies them
  (`sha256sum -c captures.sha256` from this directory).
- `manifest.json` — machine-readable provenance: revision, base, commands, fixture and
  font hashes, seeded inventory, per-capture state, sizes, DPR, locale, settings and rows.
- `fixtures/` — the generated reference fixture tree, committed so the library/import
  states can be reproduced without running the generator; `fixtures.sha256` verifies it.
  The generator remains the source of truth: a test in `crates/shosai-app` regenerates the
  tree and fails if any byte differs.

## Captures

| Evidence id | Family | State | Rows | Client | Image | DPR | Locale | Fixture | SHA-256 (12) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `lib-wide-w1280-en` | 1B-LIB-WIDE | library | LB-01 LB-04 LB-06 LB-07 LB-11 LB-12 LB-16 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `9d0b8f5e8cfc` |
| `lib-wide-w900-en` | 1B-LIB-WIDE | library | LB-01 LB-07 LB-11 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) | `514e018fa911` |
| `lib-wide-w1280-ja` | 1B-LIB-WIDE | library | LB-03 LB-04 LB-05 LB-07 LB-11 LB-13 | 1280×800 | 1280×800 | 1 | JA | G1 seeded library (46 books) + G3 Japanese/mixed metadata | `0da80e214f58` |
| `lib-wide-w1280-dpr2` | 1B-LIB-WIDE | library | LB-15 | 1280×800 | 2560×1600 | 2 | MIX | G1 seeded library (46 books) | `c0cce6139237` |
| `lib-compact-c390-en` | 1B-LIB-COMPACT | library | LB-02 LB-05 LB-12 LB-18 | 390×844 | 390×844 | 1 | EN | G1 seeded library (46 books) | `b5320113375b` |
| `lib-compact-c390-ja` | 1B-LIB-COMPACT | library | LB-02 LB-03 LB-05 LB-13 | 390×844 | 390×844 | 1 | JA | G1 seeded library (46 books) + G3 Japanese/mixed metadata | `4b4446cb48af` |
| `lib-breakpoint-759-en` | 1B-LIB-COMPACT | library | LB-03 | 759×700 | 759×700 | 1 | EN | G1 seeded library (46 books) | `8871f6604292` |
| `lib-breakpoint-760-en` | 1B-LIB-COMPACT | library | LB-03 | 760×700 | 760×700 | 1 | EN | G1 seeded library (46 books) | `a264b981f38f` |
| `lib-breakpoint-761-en` | 1B-LIB-COMPACT | library | LB-03 | 761×700 | 761×700 | 1 | EN | G1 seeded library (46 books) | `51dc9551b44a` |
| `lib-compact-c390-dpr2` | 1B-LIB-COMPACT | library | LB-15 | 390×844 | 780×1688 | 2 | EN | G1 seeded library (46 books) | `0c882467ee99` |
| `lib-state-search-ja-w1280` | 1B-LIB-STATE | library | LB-08 | 1280×800 | 1280×800 | 1 | MIX | G1 seeded library (46 books) + G3 Japanese/mixed metadata | `4757091a4571` |
| `lib-state-search-no-matches-w1280` | 1B-LIB-STATE | library | LB-08 LB-19 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `aa325fd73acd` |
| `lib-state-filter-pdf-w1280` | 1B-LIB-STATE | library | LB-06 LB-08 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `f4d6461eb11e` |
| `lib-state-search-with-filter-w1280` | 1B-LIB-STATE | library | LB-08 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `5a72a679290e` |
| `lib-state-loading-skeleton-w1280` | 1B-LIB-STATE | library | LB-17 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `8625a738f4b1` |
| `lib-state-loading-more-w1280` | 1B-LIB-STATE | library | LB-22 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `cc336c927f0a` |
| `lib-state-paged-w1280` | 1B-LIB-STATE | library | LB-22 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `ccd4b7dff65f` |
| `lib-state-empty-w1280` | 1B-LIB-STATE | library | LB-18 | 1280×800 | 1280×800 | 1 | EN | empty disposable store | `e66a921972a5` |
| `lib-state-empty-c390` | 1B-LIB-STATE | library | LB-18 | 390×844 | 390×844 | 1 | EN | empty disposable store | `cd0af8ef9904` |
| `lib-state-load-error-w1280` | 1B-LIB-STATE | library | LB-20 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `07d207866184` |
| `lib-state-storage-error-w900` | 1B-LIB-STATE | library | LB-20 | 900×700 | 900×700 | 1 | EN | no store (real open failure) | `33bb83d4097d` |
| `lib-state-book-menu-w1280` | 1B-LIB-STATE | library | LB-14 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `529e78183de9` |
| `lib-state-remove-modal-w1280` | 1B-LIB-STATE | library | LB-14 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `103a6c4ddd21` |
| `lib-state-remove-pending-w1280` | 1B-LIB-STATE | library | LB-14 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `e466c87e9f70` |
| `lib-meta-no-cover-w1280` | 1B-LIB-META | library | LB-12 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `4e1edb936001` |
| `lib-meta-no-cover-c390` | 1B-LIB-META | library | LB-12 | 390×844 | 390×844 | 1 | EN | G1 seeded library (46 books) | `2eb2ba013539` |
| `lib-meta-long-ja-w1280` | 1B-LIB-META | library | LB-13 | 1280×800 | 1280×800 | 1 | MIX | G3 Japanese/mixed metadata | `8a3a4f996f58` |
| `lib-meta-long-ja-c390` | 1B-LIB-META | library | LB-13 | 390×844 | 390×844 | 1 | MIX | G3 Japanese/mixed metadata | `b16eac28303e` |
| `import-entry-w900-en` | 1B-IMPORT | library+import-dialog | IM-01 IM-10 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `db7cb12fa19d` |
| `import-entry-w900-ja` | 1B-IMPORT | library+import-dialog | IM-01 IM-10 | 900×700 | 900×700 | 1 | JA | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `0303a921a240` |
| `import-entry-c390-en` | 1B-IMPORT | library+import-dialog | IM-10 | 390×844 | 390×844 | 1 | EN | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `5efd99494527` |
| `import-discovery-enumerating-w900` | 1B-IMPORT | library+import-dialog | IM-03 IM-10 | 900×700 | 900×700 | 1 | JA | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `39437c434f02` |
| `import-discovery-checking-w900` | 1B-IMPORT | library+import-dialog | IM-03 | 900×700 | 900×700 | 1 | JA | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `7418e8b07597` |
| `import-review-w900-en` | 1B-IMPORT | library+import-dialog | IM-04 IM-05 IM-06 IM-07 IM-10 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `cd9e8c433293` |
| `import-review-w900-ja` | 1B-IMPORT | library+import-dialog | IM-04 IM-05 IM-06 IM-07 IM-12 | 900×700 | 900×700 | 1 | JA | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `b5e6c72f7af5` |
| `import-review-no-match-w900-ja` | 1B-IMPORT | library+import-dialog | IM-04 | 900×700 | 900×700 | 1 | JA | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `655fecfd318e` |
| `import-review-deselect-all-w900-en` | 1B-IMPORT | library+import-dialog | IM-04 IM-05 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `dae24deb86ca` |
| `import-files-selection-w900-ja` | 1B-IMPORT | library+import-dialog | IM-04 IM-12 | 900×700 | 900×700 | 1 | JA | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `62fce9cca88c` |
| `import-no-supported-w900-ja` | 1B-IMPORT | library+import-dialog | IM-04 | 900×700 | 900×700 | 1 | JA | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `26fe8234d8ee` |
| `import-storage-copy-w900-en` | 1B-IMPORT | library+import-dialog | IM-07 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `5faa95a07310` |
| `import-storage-current-w900-en` | 1B-IMPORT | library+import-dialog | IM-07 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `49946f7776ea` |
| `import-progress-w900-en` | 1B-IMPORT | library+import-dialog | IM-08 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `1a5e9bb47739` |
| `import-completed-w900-en` | 1B-IMPORT | library+import-dialog | IM-08 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) + import sources | `3c3b253c0882` |
| `import-review-dpr2-w900` | 1B-IMPORT | library+import-dialog | IM-10 | 900×700 | 1800×1400 | 2 | EN | G1 seeded library (46 books) + import folder | `d3c9c7c2a98b` |
| `settings-wide-w900-en` | 1B-SETTINGS | settings | ST-01 ST-02 ST-04 ST-05 ST-09 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) | `b5f8c243a2e3` |
| `settings-wide-w900-ja` | 1B-SETTINGS | settings | ST-01 ST-02 ST-04 ST-05 ST-09 | 900×700 | 900×700 | 1 | JA | G1 seeded library (46 books) | `8e950db9b50b` |
| `settings-compact-c390-en` | 1B-SETTINGS | settings | ST-09 ST-01 | 390×844 | 390×844 | 1 | EN | G1 seeded library (46 books) | `daa77f7ab3f7` |
| `settings-compact-c390-ja` | 1B-SETTINGS | settings | ST-09 ST-01 | 390×844 | 390×844 | 1 | JA | G1 seeded library (46 books) | `cd08d9129ac3` |
| `settings-changed-w900-en` | 1B-SETTINGS | settings | ST-04 ST-05 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) | `1be1210e2bcf` |
| `settings-move-dialog-w900-ja` | 1B-SETTINGS | settings | ST-03 ST-07 | 900×700 | 900×700 | 1 | JA | G1 seeded library (46 books) | `0db716f791ad` |
| `settings-move-progress-w900-en` | 1B-SETTINGS | settings | ST-03 ST-07 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) | `e3a6ef1dae91` |
| `settings-error-w900-en` | 1B-SETTINGS | settings | ST-06 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) | `515b277e8493` |
| `settings-disabled-importing-w900-en` | 1B-SETTINGS | settings | ST-07 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) | `df5629189048` |
| `settings-disabled-removing-w900-en` | 1B-SETTINGS | settings | ST-07 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) | `df5629189048` |
| `settings-unavailable-w900-en` | 1B-SETTINGS | settings | ST-07 | 900×700 | 900×700 | 1 | EN | no store (real open failure) | `929c995fa018` |
| `settings-compact-c390-dpr2-ja` | 1B-SETTINGS | settings | ST-09 | 390×844 | 780×1688 | 2 | JA | G1 seeded library (46 books) | `94fb38512383` |

## State derivation and settings

### `lib-wide-w1280-en`

- Family: 1B-LIB-WIDE · state: library
- State: seeded library loaded through `Message::Initialized` + the real library page and cover tasks
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `lib-wide-w900-en`

- Family: 1B-LIB-WIDE · state: library
- State: seeded library loaded through `Message::Initialized` + the real library page and cover tasks
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: Iced default window (`main.rs`); wide under both breakpoints, so it is a wide reference and not a compact one

### `lib-wide-w1280-ja`

- Family: 1B-LIB-WIDE · state: library
- State: as the loaded library, then `Message::SelectLanguage(Japanese)`
- Settings: language=ja (persisted by `Message::SelectLanguage`)

### `lib-wide-w1280-dpr2`

- Family: 1B-LIB-WIDE · state: library
- State: as the loaded library, rendered at DPR 2
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: DPR 2 sharpness subset (specification `D2`); composition is identical to `lib-wide-w1280-en`, only the raster density differs
- Note: cover bitmaps come from the seeded cover blobs; the lazy-load path itself (`sensor().on_show`) needs a real window and is not exercised here

### `lib-compact-c390-en`

- Family: 1B-LIB-COMPACT · state: library
- State: seeded library loaded through `Message::Initialized` + the real library page and cover tasks
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `lib-compact-c390-ja`

- Family: 1B-LIB-COMPACT · state: library
- State: as the loaded library, then `Message::SelectLanguage(Japanese)`
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Note: Iced renders no `T200` text scaling, so the 200% text row stays with the accepting package

### `lib-breakpoint-759-en`

- Family: 1B-LIB-COMPACT · state: library
- State: seeded library loaded through `Message::Initialized` + the real library page and cover tasks
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: `B760±` probe: compact filter row

### `lib-breakpoint-760-en`

- Family: 1B-LIB-COMPACT · state: library
- State: seeded library loaded through `Message::Initialized` + the real library page and cover tasks
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: `B760±` probe: wide sidebar at the breakpoint

### `lib-breakpoint-761-en`

- Family: 1B-LIB-COMPACT · state: library
- State: seeded library loaded through `Message::Initialized` + the real library page and cover tasks
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: `B760±` probe: wide sidebar

### `lib-compact-c390-dpr2`

- Family: 1B-LIB-COMPACT · state: library
- State: as the loaded library, rendered at DPR 2
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: DPR 2 sharpness subset (specification `D2`)

### `lib-state-search-ja-w1280`

- Family: 1B-LIB-STATE · state: library
- State: `Message::LibrarySearchChanged("図書館")` settled through its debounce
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `lib-state-search-no-matches-w1280`

- Family: 1B-LIB-STATE · state: library
- State: `Message::LibrarySearchChanged("no such title")` settled through its debounce
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `lib-state-filter-pdf-w1280`

- Family: 1B-LIB-STATE · state: library
- State: `Message::LibraryFilterChanged(Some(Pdf))` settled
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: The CBZ filter entry is a retained Flutter extension and has no Iced filter; Iced offers All/EPUB/PDF only

### `lib-state-search-with-filter-w1280`

- Family: 1B-LIB-STATE · state: library
- State: `Message::LibraryFilterChanged(Some(Pdf))` then `Message::LibrarySearchChanged("annual")`, both settled
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `lib-state-loading-skeleton-w1280`

- Family: 1B-LIB-STATE · state: library
- State: `Message::RefreshLibrary` dispatched without settling its page task: the first-page load state the window shows while the page loads, with the skeleton placeholders
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `lib-state-loading-more-w1280`

- Family: 1B-LIB-STATE · state: library
- State: `Message::LoadMoreLibrary` dispatched without settling its page task
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `lib-state-paged-w1280`

- Family: 1B-LIB-STATE · state: library
- State: `Message::LoadMoreLibrary` settled
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: 46 books: the first page holds 40, the second page holds 6

### `lib-state-empty-w1280`

- Family: 1B-LIB-STATE · state: library
- State: an empty disposable store loaded through `Message::Initialized`
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `lib-state-empty-c390`

- Family: 1B-LIB-STATE · state: library
- State: an empty disposable store loaded through `Message::Initialized`
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `lib-state-load-error-w1280`

- Family: 1B-LIB-STATE · state: library
- State: a real `Library::page` failure (oversized query) delivered through `Message::LibraryLoaded { result: Err(..) }`, exactly like a failing production load
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: The failure text is a real `Library` error; the library stays usable and shows the alert bar above the grid, which is Iced's load-error composition

### `lib-state-storage-error-w900`

- Family: 1B-LIB-STATE · state: library
- State: the real failure from opening a store where the data path is a file, delivered through `Message::Initialized(Err(..))`; the disposable path is replaced by a placeholder so the image stays deterministic
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: Iced shows the storage failure inside the empty-library composition (there is no library to keep usable); there is no separate storage-error alert bar

### `lib-state-book-menu-w1280`

- Family: 1B-LIB-STATE · state: library
- State: `Message::ToggleBookMenu(first book id)`
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `lib-state-remove-modal-w1280`

- Family: 1B-LIB-STATE · state: library
- State: `Message::RequestRemoveBook(first book id)`
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `lib-state-remove-pending-w1280`

- Family: 1B-LIB-STATE · state: library
- State: `Message::RequestRemoveBook` then `Message::RemoveBook` without settling its removal task
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: Runs against its own disposable seed so the removal cannot affect other captures

### `lib-meta-no-cover-w1280`

- Family: 1B-LIB-META · state: library
- State: `Message::LibrarySearchChanged("Conformance")` settled through its debounce
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: `Conformance` matches the reused redistribution-safe conformance book, which has no cover image, so the placeholder keeps the 210 px cover box

### `lib-meta-no-cover-c390`

- Family: 1B-LIB-META · state: library
- State: `Message::LibrarySearchChanged("Conformance")` settled through its debounce
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `lib-meta-long-ja-w1280`

- Family: 1B-LIB-META · state: library
- State: `Message::LibrarySearchChanged("の")` settled through its debounce: a grid of long Japanese titles and authors
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: The search returns only long Japanese titles and authors while the UI language stays English, so this is the mixed-metadata surface

### `lib-meta-long-ja-c390`

- Family: 1B-LIB-META · state: library
- State: `Message::LibrarySearchChanged("の")` settled through its debounce: a grid of long Japanese titles and authors
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `import-entry-w900-en`

- Family: 1B-IMPORT · state: library+import-dialog
- State: `Message::OpenAddBooks`
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `import-entry-w900-ja`

- Family: 1B-IMPORT · state: library+import-dialog
- State: `Message::OpenAddBooks`
- Settings: language=ja (persisted by `Message::SelectLanguage`)

### `import-entry-c390-en`

- Family: 1B-IMPORT · state: library+import-dialog
- State: `Message::OpenAddBooks`
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: Compact client: the modal keeps its 680 px maximum width inside a 390 px window

### `import-discovery-enumerating-w900`

- Family: 1B-IMPORT · state: library+import-dialog
- State: `Message::OpenAddBooks` then `Message::AddBookFolderSelected` with the discovery task not polled: the initial enumerating phase
- Settings: language=ja (persisted by `Message::SelectLanguage`)

### `import-discovery-checking-w900`

- Family: 1B-IMPORT · state: library+import-dialog
- State: `Message::OpenAddBooks` then `Message::AddBookFolderSelected` with the real discovery task polled to completion and its final `BooksDiscovered` message not delivered: the checking phase with real counts
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Note: The reading phase (`hashed_files < total_files`) is a race between the hashing worker and the polling tick; it is not deterministically capturable in-process and stays open for 6A's own renders

### `import-review-w900-en`

- Family: 1B-IMPORT · state: library+import-dialog
- State: `Message::OpenAddBooks` then a real `AddBookFolderSelected` discovery of the import folder, settled
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `import-review-w900-ja`

- Family: 1B-IMPORT · state: library+import-dialog
- State: `Message::OpenAddBooks` then a real `AddBookFolderSelected` discovery of the import folder, settled
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Note: The pre-choice storage state (no copy/keep decision yet) renders exactly like this review list, so IM-07's two choices are evidenced by the copy/current captures instead of a duplicate ask-state image

### `import-review-no-match-w900-ja`

- Family: 1B-IMPORT · state: library+import-dialog
- State: the settled review list, then `Message::AddBooksReviewSearchChanged("no such book")`
- Settings: language=ja (persisted by `Message::SelectLanguage`)

### `import-review-deselect-all-w900-en`

- Family: 1B-IMPORT · state: library+import-dialog
- State: the settled review list with the select-all-new checkbox pressed off, so every row is deselected
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: Discovery selects every non-duplicate row, so pressing select-all-new on is pixel-identical to import-review-w900-en; this capture shows the toggle in its off position: all rows cleared, the duplicate row still unchecked, and the add action disabled while nothing is selected

### `import-files-selection-w900-ja`

- Family: 1B-IMPORT · state: library+import-dialog
- State: `Message::OpenAddBooks` then a real `AddBookFilesSelected` discovery of the long Japanese file paths, settled
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Note: Long Japanese file paths; the native file picker itself cannot run in-process (IM-02)

### `import-no-supported-w900-ja`

- Family: 1B-IMPORT · state: library+import-dialog
- State: `Message::OpenAddBooks` then a real `AddBookFolderSelected` discovery of a folder with no supported books, settled
- Settings: language=ja (persisted by `Message::SelectLanguage`)

### `import-storage-copy-w900-en`

- Family: 1B-IMPORT · state: library+import-dialog
- State: the settled review list, then `Message::SelectAddBooksStorage(true)`
- Settings: import storage choice: copy into the library

### `import-storage-current-w900-en`

- Family: 1B-IMPORT · state: library+import-dialog
- State: the settled review list, then `Message::SelectAddBooksStorage(false)`
- Settings: import storage choice: keep current location

### `import-progress-w900-en`

- Family: 1B-IMPORT · state: library+import-dialog
- State: the settled review list with a storage choice, then `Message::AddSelectedBooks` without settling its import task
- Settings: import storage choice: copy into the library
- Note: The import task is started and deliberately left unsettled, so the header action shows the real cancel/progress label with 0 of N; mid-import counts are not captured because the parallel copy tasks complete in a scheduling-dependent order

### `import-completed-w900-en`

- Family: 1B-IMPORT · state: library+import-dialog
- State: the settled review list with a storage choice, then `Message::AddSelectedBooks` settled: the real post-import library
- Settings: import storage choice: copy into the library
- Note: Runs against its own disposable seed, because the import adds rows to the store
- Note: The imported books are copied into the disposable managed directory; the committed library is untouched

### `import-review-dpr2-w900`

- Family: 1B-IMPORT · state: library+import-dialog
- State: as the import review list, rendered at DPR 2
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: DPR 2 sharpness subset (specification `D2`)

### `settings-wide-w900-en`

- Family: 1B-SETTINGS · state: settings
- State: `Message::ShowSettings`
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `settings-wide-w900-ja`

- Family: 1B-SETTINGS · state: settings
- State: `Message::SelectLanguage(Japanese)` then `Message::ShowSettings`
- Settings: language=ja (persisted by `Message::SelectLanguage`)

### `settings-compact-c390-en`

- Family: 1B-SETTINGS · state: settings
- State: `Message::ShowSettings`
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: Compact settings stack the controls vertically

### `settings-compact-c390-ja`

- Family: 1B-SETTINGS · state: settings
- State: `Message::SelectLanguage(Japanese)` then `Message::ShowSettings`
- Settings: language=ja (persisted by `Message::SelectLanguage`)

### `settings-changed-w900-en`

- Family: 1B-SETTINGS · state: settings
- State: `Message::ShowSettings` then the real settings messages for add behavior, reading mode, theme, EPUB font size, line spacing and PDF zoom
- Settings: library.add_behavior=copy (persisted); reader.default_mode=continuous (persisted); reader.default_theme=dark (persisted); reader.default_epub_font_size=20 (persisted); reader.default_epub_line_spacing=2.0 (persisted); reader.default_pdf_zoom=fit-width (persisted)

### `settings-move-dialog-w900-ja`

- Family: 1B-SETTINGS · state: settings
- State: `Message::ShowSettings` then `Message::ManagedLibraryMovePlanned { result: Ok(summary) }` with the summary produced by `Library::managed_storage_summary`, standing in for the native folder picker
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Note: The book count and size come from the real `Library::managed_storage_summary`; the destination path stands in for the native folder picker's result

### `settings-move-progress-w900-en`

- Family: 1B-SETTINGS · state: settings
- State: as the move dialog, then `Message::ConfirmManagedLibraryMove` without settling its move task
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `settings-error-w900-en`

- Family: 1B-SETTINGS · state: settings
- State: `Message::ShowSettings` then `Message::ManagedLibraryMovePlanned { result: Err(..) }`
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: ST-06 acceptance stays with 6B's renders; this is the Iced reference for the error banner

### `settings-disabled-importing-w900-en`

- Family: 1B-SETTINGS · state: settings
- State: an import started for real (discovery + `Message::AddSelectedBooks` in flight), then `Message::ShowSettings`
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `settings-disabled-removing-w900-en`

- Family: 1B-SETTINGS · state: settings
- State: a removal started for real (`Message::RequestRemoveBook` + `Message::RemoveBook` in flight), then `Message::ShowSettings`
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)

### `settings-unavailable-w900-en`

- Family: 1B-SETTINGS · state: settings
- State: the storage-failure state, then `Message::ShowSettings`
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: Shows the unavailable managed location and the disabled library actions

### `settings-compact-c390-dpr2-ja`

- Family: 1B-SETTINGS · state: settings
- State: `Message::SelectLanguage(Japanese)` then `Message::ShowSettings`
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Note: DPR 2 sharpness subset (specification `D2`)

## Matrix coverage

Covered by a capture in this set:

| Row | Captures |
| --- | --- |
| LB-01 | `lib-wide-w1280-en` `lib-wide-w900-en` |
| LB-02 | `lib-compact-c390-en` `lib-compact-c390-ja` |
| LB-03 | `lib-wide-w1280-ja` `lib-compact-c390-ja` `lib-breakpoint-759-en` `lib-breakpoint-760-en` `lib-breakpoint-761-en` |
| LB-04 | `lib-wide-w1280-en` `lib-wide-w1280-ja` |
| LB-05 | `lib-wide-w1280-ja` `lib-compact-c390-en` `lib-compact-c390-ja` |
| LB-06 | `lib-wide-w1280-en` `lib-state-filter-pdf-w1280` |
| LB-07 | `lib-wide-w1280-en` `lib-wide-w900-en` `lib-wide-w1280-ja` |
| LB-08 | `lib-state-search-ja-w1280` `lib-state-search-no-matches-w1280` `lib-state-filter-pdf-w1280` `lib-state-search-with-filter-w1280` |
| LB-11 | `lib-wide-w1280-en` `lib-wide-w900-en` `lib-wide-w1280-ja` |
| LB-12 | `lib-wide-w1280-en` `lib-compact-c390-en` `lib-meta-no-cover-w1280` `lib-meta-no-cover-c390` |
| LB-13 | `lib-wide-w1280-ja` `lib-compact-c390-ja` `lib-meta-long-ja-w1280` `lib-meta-long-ja-c390` |
| LB-14 | `lib-state-book-menu-w1280` `lib-state-remove-modal-w1280` `lib-state-remove-pending-w1280` |
| LB-15 | `lib-wide-w1280-dpr2` `lib-compact-c390-dpr2` |
| LB-16 | `lib-wide-w1280-en` |
| LB-17 | `lib-state-loading-skeleton-w1280` |
| LB-18 | `lib-compact-c390-en` `lib-state-empty-w1280` `lib-state-empty-c390` |
| LB-19 | `lib-state-search-no-matches-w1280` |
| LB-20 | `lib-state-load-error-w1280` `lib-state-storage-error-w900` |
| LB-22 | `lib-state-loading-more-w1280` `lib-state-paged-w1280` |
| IM-01 | `import-entry-w900-en` `import-entry-w900-ja` |
| IM-03 | `import-discovery-enumerating-w900` `import-discovery-checking-w900` |
| IM-04 | `import-review-w900-en` `import-review-w900-ja` `import-review-no-match-w900-ja` `import-review-deselect-all-w900-en` `import-files-selection-w900-ja` `import-no-supported-w900-ja` |
| IM-05 | `import-review-w900-en` `import-review-w900-ja` `import-review-deselect-all-w900-en` |
| IM-06 | `import-review-w900-en` `import-review-w900-ja` |
| IM-07 | `import-review-w900-en` `import-review-w900-ja` `import-storage-copy-w900-en` `import-storage-current-w900-en` |
| IM-08 | `import-progress-w900-en` `import-completed-w900-en` |
| IM-10 | `import-entry-w900-en` `import-entry-w900-ja` `import-entry-c390-en` `import-discovery-enumerating-w900` `import-review-w900-en` `import-review-dpr2-w900` |
| IM-12 | `import-review-w900-ja` `import-files-selection-w900-ja` |
| ST-01 | `settings-wide-w900-en` `settings-wide-w900-ja` `settings-compact-c390-en` `settings-compact-c390-ja` |
| ST-02 | `settings-wide-w900-en` `settings-wide-w900-ja` |
| ST-03 | `settings-move-dialog-w900-ja` `settings-move-progress-w900-en` |
| ST-04 | `settings-wide-w900-en` `settings-wide-w900-ja` `settings-changed-w900-en` |
| ST-05 | `settings-wide-w900-en` `settings-wide-w900-ja` `settings-changed-w900-en` |
| ST-06 | `settings-error-w900-en` |
| ST-07 | `settings-move-dialog-w900-ja` `settings-move-progress-w900-en` `settings-disabled-importing-w900-en` `settings-disabled-removing-w900-en` `settings-unavailable-w900-en` |
| ST-09 | `settings-wide-w900-en` `settings-wide-w900-ja` `settings-compact-c390-en` `settings-compact-c390-ja` `settings-compact-c390-dpr2-ja` |

Covered by the manifest itself (provenance, no image):

| Row | Satisfied by |
| --- | --- |
| XA-10 | satisfied by `manifest.json` with `captures.sha256`, `fixtures.sha256` and the README rather than by an image |

Pending, not covered by Iced captures (with owner and reason):

| Row | Owner | Reason |
| --- | --- | --- |
| LB-09 | pending | 3A — Flutter keyboard behavior with no Iced counterpart |
| LB-10 | pending | 3A — 200% text scaling is Flutter-only (`T200`) |
| LB-21 | pending | 3C — cleanup/deletion debt policy is retained Flutter/plan-owned |
| LB-23 | pending | 2C — library palette states are mapped and rendered by 2C (`2C-PALETTE`) |
| IM-02 | pending | 6A — native pickers and the Android provider path cannot run in-process |
| IM-09 | pending | 6A — completion summaries are Flutter behavior per the notice policy |
| IM-11 | pending | 2A — dialog accessibility is Flutter-owned (`WT`) |
| ST-08 | pending | 6B — restart persistence and per-book precedence are behavioral (`WT`) |
| ST-10 | pending | 6B/6A — capability-parity review record, not a capture |
| RD-* | pending | 1C — reader captures use this harness in package 1C |

## Captures that intentionally share pixels

| Capture | Identical to | Reason |
| --- | --- | --- |
| `settings-disabled-importing-w900-en` | `settings-disabled-removing-w900-en` | The settings screen disables exactly the same managed-library actions while an import and while a removal run, and it renders no progress indicator, so both states legitimately render the same image; `assert_reached` still checks each state separately |

## Fixtures

Generated in-repo: every archive and image is produced by the deterministic generator above, no third-party content is embedded, and the generator reads no clock, locale or random source. The reused conformance book keeps its own documented redistribution statement.

Generated files: 58 (all hashed in `fixtures.sha256` and in `manifest.json`). The
dangling-symlink discovery-failure fixture could be created on this platform: true.

| Reused fixture | SHA-256 | Provenance | Purpose |
| --- | --- | --- | --- |
| `crates/shosai-core/tests/fixtures/epub-conformance/conformance.epub` | `2f9687c08a59` (verified) | crates/shosai-core/tests/fixtures/epub-conformance/README.md + SHA256SUMS (documented redistribution-safe) | conformance sampler book in the seeded library |

## Fonts

| Role | SHA-256 |
| --- | --- |
| InterVariable.ttf (type.ui.family.latin) | `4989b125924991b90d05b2d16e0e388c48f7d5bb8b30539bbf9c755278d0ccaf` |
| NotoSansJP-Variable.ttf (type.ui.family.japanese) | `c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f` |
| math font (type.math.family) | `4989b125924991b90d05b2d16e0e388c48f7d5bb8b30539bbf9c755278d0ccaf` |

## Known limitations

- Iced has no text scaling (`T200`), no CBZ filter entry, no tiled continuous render and no decision-11 tab overflow: those rows have no Iced counterpart and are not fabricated here; they stay with the Flutter/renderer packages.
- The native file/folder pickers (IM-02, ST-02's change-location flow) cannot run in-process; captures start from the discovered/reviewed state that follows a pick, and the move dialog uses the real storage summary with a fixed destination path.
- Covers are decoded by the real batch decode path during seeding, and the per-card `sensor().on_show` cover request is exercised too: the capture delivers the frame's redraw event, dispatches what the view asks for and draws the settled frame. Books with no cover blob keep the placeholder card.
- The capture renders in-process from the disposable data root, so application text that names a real path (discovery-failure rows, the managed-library path) shows `/tmp/shosai-reference-shots-1b/…`. That root is fixed by default and `SHOSAI_REFERENCE_SHOTS_DATA_DIR` moves it; a run with a different data root renders different bytes, which verification reports instead of hiding.
- Import progress counters are captured at their deterministic point: the in-flight capture shows the header action with `0/N` while the copy tasks are undelivered. Mid-import numbers are not captured because the parallel prepare/copy tasks complete in a scheduling-dependent order, so a partial progress reading is not reproducible.
- The import discovery 'reading' phase is a race between the hashing worker and the polling tick and is not deterministically capturable in-process; the enumerating and checking phases are captured with real counts.
- Rendering is in-process software rasterization, not a compositor screenshot: window decorations, native menus, toasts and animations are outside the capture.
