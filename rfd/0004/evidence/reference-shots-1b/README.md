# 1B reference captures (Iced, package 1B)

Generated evidence for the `1B-LIB-*`, `1B-IMPORT` and `1B-SETTINGS` families of the Flutter UI reference specification. These images are the **Iced reference**, not
acceptance evidence for the Flutter restoration: each accepting package still produces
and inspects its own renders (specification §4.0).

- Entry point: `make reference-shots`
- Command: `make reference-shots`
- Capture-code revision: `4cce3370aa60c425c953440277b555404465c766` (from jj @ working-copy commit, Jujutsu change `xqystyrmpvvvvonzonkrlllzvppxmoox`, bookmark `none`)
- Revision note: `capture_code_revision` is the working-copy commit id at render time. Jujutsu rewrites a commit id when its change is described or committed, so the durable mapping is the stable `capture_code_change_id` (resolve it with `jj log -r 'change_id(<id>)'` in the pinned Jujutsu, which is the command `docs/reference-captures.md` records) together with the commit that contains this evidence directory, which is the capture code revision the evidence is committed at; `make reference-shots VERIFY=1` re-renders this evidence byte-identically at any revision that carries the change.
- Pinned design base: `1e54270a6bb24f15630ece336a0575bdbe5be113` — main@origin #108 (refactor(flutter): organize the frontend into Elm modules mirroring Iced)
- Preference baseline: `language=en-US`, `library.add_behavior=ask`, `reader.default_mode=paginated`, `reader.default_theme=light`, `reader.default_epub_font_size=16`, `reader.default_epub_line_spacing=1.6`, `reader.default_pdf_zoom=fit-page`
- Renderer: iced_tiny_skia 0.14 (software, in-process) · theme theme::application() — iced::Theme::custom(APP_BACKGROUND #F4F2ED) · default font Inter Variable (bundled InterVariable.ttf) at 16 px
- System language: en-US via `LANGUAGE` (the `System`-preference captures resolve English)
- Font discovery: font discovery pinned: the renderer's font database holds only in-memory application and Iced faces
- Why font discovery is pinned: The capture entry point exports `FONTCONFIG_FILE` pointing at a fontconfig configuration whose only font directory is empty, so the renderer's font database holds exactly the application fonts and Iced's built-ins, all loaded from memory. Host fonts would make the images depend on the machine's installed fonts.
- Native PDFium (run metadata, exempt from comparison): /nix/store/lzlnjc9fmn7wjrgaxfcpqnaa281n1w2w-pdfium-binaries-7643/lib/libpdfium.so (sha256 6cfbebd7c8dff974f18637e725290bca41be3ea0d928f5598e1d4526f4fd0d70)
- Generated: linux · x86_64 (rustc rustc 1.94.0 (4a4ef493e 2026-03-02))
- Seeded library: 46 books (`G1 library seed: 14 featured books (incl. one reused conformance book and two without covers) + 32 filler books, one continue-reading entry`), page size 40, order `last_read DESC NULLS LAST, date_added DESC, id DESC`
- Continue-reading seed: The Quiet Cartographer (library/featured/quiet-cartographer.epub) at 42%
- Captures: 59

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
| `lib-wide-w1280-en` | 1B-LIB-WIDE | library | LB-01 LB-03 LB-04 LB-06 LB-07 LB-11 LB-12 LB-16 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `7e105495933c` |
| `lib-wide-w900-en` | 1B-LIB-WIDE | library | LB-01 LB-07 LB-11 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) | `2bf30833feb3` |
| `lib-wide-w1280-ja` | 1B-LIB-WIDE | library | LB-03 LB-04 LB-07 LB-11 LB-13 | 1280×800 | 1280×800 | 1 | JA | G1 seeded library (46 books) + G3 Japanese/mixed metadata | `9e9d72673e18` |
| `lib-wide-w1280-dpr2` | 1B-LIB-WIDE | library | LB-15 | 1280×800 | 2560×1600 | 2 | MIX | G1 seeded library (46 books) | `00a45d4a369c` |
| `lib-compact-c390-en` | 1B-LIB-COMPACT | library | LB-02 LB-05 LB-12 | 390×844 | 390×844 | 1 | EN | G1 seeded library (46 books) | `6bd80dfcbcd0` |
| `lib-compact-c390-ja` | 1B-LIB-COMPACT | library | LB-02 LB-05 LB-13 | 390×844 | 390×844 | 1 | JA | G1 seeded library (46 books) + G3 Japanese/mixed metadata | `28ea12a34b17` |
| `lib-breakpoint-759-en` | 1B-LIB-COMPACT | library | LB-02 LB-03 | 759×700 | 759×700 | 1 | EN | G1 seeded library (46 books) | `be35b192476c` |
| `lib-breakpoint-760-en` | 1B-LIB-COMPACT | library | LB-02 LB-03 | 760×700 | 760×700 | 1 | EN | G1 seeded library (46 books) | `519e8446f04d` |
| `lib-breakpoint-761-en` | 1B-LIB-COMPACT | library | LB-02 LB-03 | 761×700 | 761×700 | 1 | EN | G1 seeded library (46 books) | `56adffdbef10` |
| `lib-breakpoint-759-ja` | 1B-LIB-COMPACT | library | LB-03 | 759×700 | 759×700 | 1 | JA | G1 seeded library (46 books) + G3 Japanese/mixed metadata | `9dc527500879` |
| `lib-breakpoint-760-ja` | 1B-LIB-COMPACT | library | LB-03 | 760×700 | 760×700 | 1 | JA | G1 seeded library (46 books) + G3 Japanese/mixed metadata | `dd7218a17235` |
| `lib-breakpoint-761-ja` | 1B-LIB-COMPACT | library | LB-03 | 761×700 | 761×700 | 1 | JA | G1 seeded library (46 books) + G3 Japanese/mixed metadata | `242199da1cc7` |
| `lib-compact-c390-dpr2` | 1B-LIB-COMPACT | library | LB-15 | 390×844 | 780×1688 | 2 | EN | G1 seeded library (46 books) | `2a624863c446` |
| `lib-state-search-ja-w1280` | 1B-LIB-STATE | library | LB-08 | 1280×800 | 1280×800 | 1 | MIX | G1 seeded library (46 books) + G3 Japanese/mixed metadata | `8c0c60fab44e` |
| `lib-state-search-no-matches-w1280` | 1B-LIB-STATE | library | LB-08 LB-19 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `c9cc742c36ce` |
| `lib-state-filter-pdf-w1280` | 1B-LIB-STATE | library | LB-06 LB-08 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `b6e8e69e59e3` |
| `lib-state-search-with-filter-w1280` | 1B-LIB-STATE | library | LB-08 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `ce16c7764fe3` |
| `lib-state-loading-skeleton-w1280` | 1B-LIB-STATE | library | LB-17 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `c9802989ddb6` |
| `lib-state-loading-more-w1280` | 1B-LIB-STATE | library | LB-22 | 1280×3250 | 1280×3250 | 1 | EN | G1 seeded library (46 books) | `8f0c87b51a15` |
| `lib-state-paged-w1280` | 1B-LIB-STATE | library | LB-22 | 1280×3250 | 1280×3250 | 1 | EN | G1 seeded library (46 books) | `857c4c71cc7d` |
| `lib-state-empty-w1280` | 1B-LIB-STATE | library | LB-18 | 1280×800 | 1280×800 | 1 | EN | empty disposable store | `391bbdec5994` |
| `lib-state-empty-c390` | 1B-LIB-STATE | library | LB-18 | 390×844 | 390×844 | 1 | EN | empty disposable store | `db7db8d95fae` |
| `lib-state-load-error-w1280` | 1B-LIB-STATE | library | LB-20 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `1bc299fc8931` |
| `lib-state-storage-error-w900` | 1B-LIB-STATE | library | LB-20 | 900×700 | 900×700 | 1 | EN | no store (real open failure) | `fe0c4338e603` |
| `lib-state-book-menu-w1280` | 1B-LIB-STATE | library | LB-14 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `5c3228625c74` |
| `lib-state-remove-modal-w1280` | 1B-LIB-STATE | library | LB-14 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `38106476365b` |
| `lib-state-remove-pending-w1280` | 1B-LIB-STATE | library | LB-14 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `3b8aa4ed4a3a` |
| `lib-meta-no-cover-w1280` | 1B-LIB-META | library | LB-12 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) | `caae28851b53` |
| `lib-meta-no-cover-c390` | 1B-LIB-META | library | LB-12 | 390×844 | 390×844 | 1 | EN | G1 seeded library (46 books) | `b64886721865` |
| `lib-meta-long-ja-w1280` | 1B-LIB-META | library | LB-13 | 1280×800 | 1280×800 | 1 | MIX | G3 Japanese/mixed metadata | `f8fad18cb544` |
| `lib-meta-long-ja-c390` | 1B-LIB-META | library | LB-13 | 390×844 | 390×844 | 1 | MIX | G3 Japanese/mixed metadata | `2fbaac7caa1d` |
| `import-entry-w900-en` | 1B-IMPORT | library+import-dialog | IM-01 IM-10 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `f58f7aae892b` |
| `import-entry-w900-ja` | 1B-IMPORT | library+import-dialog | IM-01 IM-10 | 900×700 | 900×700 | 1 | JA | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `a6cb910711e9` |
| `import-entry-c390-en` | 1B-IMPORT | library+import-dialog | IM-10 | 390×844 | 390×844 | 1 | EN | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `ea557f0a0fb5` |
| `import-discovery-enumerating-w900` | 1B-IMPORT | library+import-dialog | IM-03 IM-10 | 900×700 | 900×700 | 1 | JA | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `568593be55e0` |
| `import-discovery-checking-w900` | 1B-IMPORT | library+import-dialog | IM-03 | 900×700 | 900×700 | 1 | JA | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `aeb61b66cfda` |
| `import-review-w900-en` | 1B-IMPORT | library+import-dialog | IM-04 IM-05 IM-06 IM-07 IM-10 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `0d67cdca5008` |
| `import-review-w900-ja` | 1B-IMPORT | library+import-dialog | IM-04 IM-05 IM-06 IM-07 IM-12 | 900×700 | 900×700 | 1 | JA | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `94206d869467` |
| `import-review-no-match-w900-ja` | 1B-IMPORT | library+import-dialog | IM-04 | 900×700 | 900×700 | 1 | JA | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `4d5d3b9e2730` |
| `import-review-deselect-all-w900-en` | 1B-IMPORT | library+import-dialog | IM-04 IM-05 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `d5cad6292a9e` |
| `import-files-selection-w900-ja` | 1B-IMPORT | library+import-dialog | IM-04 IM-12 | 900×700 | 900×700 | 1 | JA | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `127d9638cbd8` |
| `import-no-supported-w900-ja` | 1B-IMPORT | library+import-dialog | IM-04 | 900×700 | 900×700 | 1 | JA | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `536fa1d18b34` |
| `import-storage-copy-w900-en` | 1B-IMPORT | library+import-dialog | IM-07 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `834b50b7efd8` |
| `import-storage-current-w900-en` | 1B-IMPORT | library+import-dialog | IM-07 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `fa4c54ac6852` |
| `import-progress-w900-en` | 1B-IMPORT | library | IM-08 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths) | `c24c3e127d2a` |
| `import-completed-w900-en` | 1B-IMPORT | library | IM-08 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) + import sources | `f3826e282faf` |
| `import-review-dpr2-w900` | 1B-IMPORT | library+import-dialog | IM-10 | 900×700 | 1800×1400 | 2 | EN | G1 seeded library (46 books) + import folder | `86391c5d00ef` |
| `settings-wide-w900-en` | 1B-SETTINGS | settings | ST-01 ST-02 ST-04 ST-05 ST-09 | 900×1200 | 900×1200 | 1 | EN | G1 seeded library (46 books) | `0a8840cca326` |
| `settings-wide-w900-ja` | 1B-SETTINGS | settings | ST-01 ST-02 ST-04 ST-05 ST-09 | 900×1200 | 900×1200 | 1 | JA | G1 seeded library (46 books) | `ff5317114ff3` |
| `settings-compact-c390-en` | 1B-SETTINGS | settings | ST-09 ST-01 | 390×844 | 390×844 | 1 | EN | G1 seeded library (46 books) | `d931aa3c329b` |
| `settings-compact-c390-ja` | 1B-SETTINGS | settings | ST-09 ST-01 | 390×844 | 390×844 | 1 | JA | G1 seeded library (46 books) | `a970294bee22` |
| `settings-changed-w900-en` | 1B-SETTINGS | settings | ST-04 ST-05 | 900×1200 | 900×1200 | 1 | EN | G1 seeded library (46 books) | `c2c1906889cc` |
| `settings-move-dialog-w900-ja` | 1B-SETTINGS | settings | ST-03 ST-07 | 900×700 | 900×700 | 1 | JA | G1 seeded library (46 books) | `2077d72a3aa5` |
| `settings-move-progress-w900-en` | 1B-SETTINGS | settings | ST-03 ST-07 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) | `708a42b15b27` |
| `settings-error-w900-en` | 1B-SETTINGS | settings | ST-06 | 900×1200 | 900×1200 | 1 | EN | G1 seeded library (46 books) | `2aa09273f2a0` |
| `settings-disabled-importing-w900-en` | 1B-SETTINGS | settings | ST-07 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) | `4945e2626c53` |
| `settings-disabled-removing-w900-en` | 1B-SETTINGS | settings | ST-07 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) | `4945e2626c53` |
| `settings-unavailable-w900-en` | 1B-SETTINGS | settings | ST-07 | 900×700 | 900×700 | 1 | EN | no store (real open failure) | `8435eddc7512` |
| `settings-compact-c390-dpr2-ja` | 1B-SETTINGS | settings | ST-09 | 390×844 | 780×1688 | 2 | JA | G1 seeded library (46 books) | `023b3a133ed1` |

## State derivation and settings

### `lib-wide-w1280-en`

- Family: 1B-LIB-WIDE · state: library
- State: seeded library loaded through `Message::Initialized` + the real library page and cover tasks
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: `LB-03` lists the wide side of the breakpoint row in both families: the boundary itself is covered by the `B760±` probes, this capture shows the wide composition the breakpoint switches to

### `lib-wide-w900-en`

- Family: 1B-LIB-WIDE · state: library
- State: seeded library loaded through `Message::Initialized` + the real library page and cover tasks
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: Iced default window (`main.rs`); wide under both breakpoints, so it is a wide reference and not a compact one

### `lib-wide-w1280-ja`

- Family: 1B-LIB-WIDE · state: library
- State: as the loaded library, then `Message::SelectLanguage(Japanese)`
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Note: `LB-05` is the compact filter row and is covered by the `C390` captures, not by this wide one
- Note: `LB-03` lists the wide side of the breakpoint row: this is the Japanese wide composition the breakpoint switches to, while the boundary itself is covered by the `B760±` probes

### `lib-wide-w1280-dpr2`

- Family: 1B-LIB-WIDE · state: library
- State: as the loaded library, rendered at DPR 2
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: DPR 2 sharpness subset (specification `D2`); composition is identical to `lib-wide-w1280-en`, only the raster density differs
- Note: The cards' cover sensors run through the capture's redraw path, so a visible card without a decoded cover requests it exactly like a real window; a real window's scroll- and paging-driven sensor transitions are not reproduced offscreen

### `lib-compact-c390-en`

- Family: 1B-LIB-COMPACT · state: library
- State: seeded library loaded through `Message::Initialized` + the real library page and cover tasks
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: `LB-12` is the missing-cover card in compact form; it uses the populated seed, so the empty-library row `LB-18` is covered by `lib-state-empty-c390` instead

### `lib-compact-c390-ja`

- Family: 1B-LIB-COMPACT · state: library
- State: as the loaded library, then `Message::SelectLanguage(Japanese)`
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Note: Iced renders no `T200` text scaling, so the 200% text row stays with the accepting package

### `lib-breakpoint-759-en`

- Family: 1B-LIB-COMPACT · state: library
- State: seeded library loaded through `Message::Initialized` + the real library page and cover tasks
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: `B760±` probe: the compact composition (`LB-02`) and the compact side of the breakpoint (`LB-03`)

### `lib-breakpoint-760-en`

- Family: 1B-LIB-COMPACT · state: library
- State: seeded library loaded through `Message::Initialized` + the real library page and cover tasks
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: `B760±` probe: the breakpoint itself, where `LB-02`'s compact composition ends (`LB-03` asks for both sides), and the wide sidebar starts

### `lib-breakpoint-761-en`

- Family: 1B-LIB-COMPACT · state: library
- State: seeded library loaded through `Message::Initialized` + the real library page and cover tasks
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: `B760±` probe: the wide sidebar, so the compact composition cannot remain above the breakpoint in `LB-02`'s configuration

### `lib-breakpoint-759-ja`

- Family: 1B-LIB-COMPACT · state: library
- State: as the loaded library, then `Message::SelectLanguage(Japanese)`
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Note: `B760±` probe: compact filter row, Japanese interface

### `lib-breakpoint-760-ja`

- Family: 1B-LIB-COMPACT · state: library
- State: as the loaded library, then `Message::SelectLanguage(Japanese)`
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Note: `B760±` probe: wide sidebar at the breakpoint, Japanese interface

### `lib-breakpoint-761-ja`

- Family: 1B-LIB-COMPACT · state: library
- State: as the loaded library, then `Message::SelectLanguage(Japanese)`
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Note: `B760±` probe: wide sidebar, Japanese interface

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
- Note: The viewport is taller than the usual `W1280` window (`W1280_TALL`): the loading-more indicator and the paging row are the last items of the library scroll column, below the 40-card first page, and this renderer has no scroll interaction, so a taller window is the only way to show them without inventing a scroll position

### `lib-state-paged-w1280`

- Family: 1B-LIB-STATE · state: library
- State: `Message::LoadMoreLibrary` settled
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: 46 books: the first page holds 40, the second page holds 6
- Note: `W1280_TALL`, for the same reason as `lib-state-loading-more-w1280`: the paging row is the last item of the library scroll column

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

- Family: 1B-IMPORT · state: library
- State: the settled review list with a storage choice, then `Message::AddSelectedBooks` without settling its import task
- Settings: import storage choice: copy into the library
- Note: `AddSelectedBooks` closes the dialog before the copy starts, so this capture is the library with the header action in its import state, not a dialog state
- Note: The import task is started and deliberately left unsettled, so the header action shows the real cancel/progress label with 0 of N; mid-import counts are not captured because the parallel copy tasks complete in a scheduling-dependent order

### `import-completed-w900-en`

- Family: 1B-IMPORT · state: library
- State: the settled review list with a storage choice, then `Message::AddSelectedBooks` settled: the real post-import library
- Settings: import storage choice: copy into the library
- Note: The import dialog is closed by `AddSelectedBooks`, so this capture is the library after the import, with the imported book in the grid
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
- Note: `W900_TALL`: the reader-defaults controls (`ST-05`) are the last card of the settings scroll column and would sit below the fold of the usual `W900` window, which this renderer cannot scroll

### `settings-wide-w900-ja`

- Family: 1B-SETTINGS · state: settings
- State: `Message::SelectLanguage(Japanese)` then `Message::ShowSettings`
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Note: `W900_TALL`: the reader-defaults controls (`ST-05`) are the last card of the settings scroll column and would sit below the fold of the usual `W900` window, which this renderer cannot scroll

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
- Note: `W900_TALL` so the changed reader defaults (`ST-05`: reading mode, theme, EPUB font size, line spacing, PDF zoom) are visible next to the changed import behavior (`ST-04`)

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
- State: `Message::ShowSettings` then `Message::ManagedLibraryMovePlanned { result: Err(..) }` with synthetic reference text, because a real permission failure cannot be triggered in-process; the banner composition is production
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Note: ST-06 acceptance stays with 6B's renders; this is the Iced reference for the error banner
- Note: The viewport is taller than the usual `W900` window (`W900_TALL`) because the alert is the last item of the settings scroll column and this renderer has no scroll interaction: a taller window is the only way to show the real banner composition without inventing a scroll position
- Note: The failure text is synthetic reference text delivered through `ManagedLibraryMovePlanned { result: Err(..) }`: no real filesystem failure is triggered, because the move target is a fixed path the capture never writes

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
| LB-02 | `lib-compact-c390-en` `lib-compact-c390-ja` `lib-breakpoint-759-en` `lib-breakpoint-760-en` `lib-breakpoint-761-en` |
| LB-03 | `lib-wide-w1280-en` `lib-wide-w1280-ja` `lib-breakpoint-759-en` `lib-breakpoint-760-en` `lib-breakpoint-761-en` `lib-breakpoint-759-ja` `lib-breakpoint-760-ja` `lib-breakpoint-761-ja` |
| LB-04 | `lib-wide-w1280-en` `lib-wide-w1280-ja` |
| LB-05 | `lib-compact-c390-en` `lib-compact-c390-ja` |
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
| LB-18 | `lib-state-empty-w1280` `lib-state-empty-c390` |
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
- Every capture needs a viewport the page fits in, because the renderer has no scroll interaction and the application exposes no message that scrolls the settings or library column: `settings-wide-*`, `settings-changed-*` and `settings-error-*` use `W900_TALL` (900×1200) and the `LB-22` paging pair uses `W1280_TALL` (1280×3250). The layout rules, the theme and the composition are unchanged; only the window is tall enough for the column.
- The generated PDF fixtures draw shapes only: PDFium resolves fonts for unembedded PDF text itself by scanning the host font directories and does not follow `FONTCONFIG_FILE`, so a text run would make a rendered cover depend on the machine's installed fonts. The native PDFium that rasterized the covers is recorded in `environment.pdfium`; a PDF reference with real typography needs an embedded, pinned font and belongs to the reader packages.
- The capture entry point runs on Linux with a pinned environment (`LANGUAGE=en-US`, `FONTCONFIG_FILE` naming an empty font directory, see docs/reference-captures.md). Another platform or an unpinned environment refuses to render rather than write images that depend on the machine.
