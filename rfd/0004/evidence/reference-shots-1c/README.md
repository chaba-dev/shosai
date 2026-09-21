# 1C reference captures (Iced, package 1C)

Generated evidence for the `1C-RD-CHROME`, `1C-RD-PANEL`, `1C-SPREAD`, `1C-EPUB-PAG`, `1C-EPUB-CONT`, `1C-PDF-PAG`, `1C-PDF-CONT`, `1C-CBZ-PAG` and `1C-CBZ-CONT` families of the Flutter UI reference specification. These images are the **Iced reference**, not
acceptance evidence for the Flutter restoration: each accepting package still produces
and inspects its own renders (specification §4.0).

- Entry point: `make reference-shots`
- Command: `make reference-shots`
- Capture-code revision: `897eee0911a422fd2501fd23aa8755beface8cfe` (from jj @ working-copy commit, Jujutsu change `nqztxuqyrklvmzqnnrqvzlsntyxkkyvo`, bookmark `none`)
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

## Reader rich-content seed (package 1C)

53 books (`1C reader seed: the shared library seed plus the reused conformance fixtures (bidi, fonts, fonts-isolation, links, mathml, table) and the generated reader-marks fixture`), page size 40, order `last_read DESC NULLS LAST, date_added DESC, id DESC`.

- Continue-reading seed: The Quiet Cartographer (library/featured/quiet-cartographer.epub) at 42%
- Captures: 60

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
| `rd-cbz-cont-w1280-en` | 1C-CBZ-CONT | reader | FM-06 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `b6f7426783d3` |
| `rd-cbz-fit-width-w1280-en` | 1C-CBZ-PAG | reader | FM-03 FM-13 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `d790a4ff4d32` |
| `rd-cbz-manual-zoom-w1280-en` | 1C-CBZ-PAG | reader | FM-03 FM-13 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `2ed05af3e6da` |
| `rd-cbz-pag-w1280-en` | 1C-CBZ-PAG | reader | FM-03 FM-13 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `7d47aac38e1e` |
| `rd-chrome-b860-859-en` | 1C-RD-CHROME | reader | RD-02 | 859×700 | 859×700 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `c12734b47331` |
| `rd-chrome-b860-860-en` | 1C-RD-CHROME | reader | RD-01 | 860×700 | 860×700 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `617c44ba93c8` |
| `rd-chrome-b860-861-en` | 1C-RD-CHROME | reader | RD-01 | 861×700 | 861×700 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `b26e05fecb6f` |
| `rd-chrome-c390-ja` | 1C-RD-CHROME | reader | RD-02 RD-06 | 390×844 | 390×844 | 1 | JA | G1 seeded library (46 books) + reader fixtures | `de3f7eb91556` |
| `rd-chrome-hover-edge-c390-ja` | 1C-RD-CHROME | reader | RD-06 | 390×844 | 390×844 | 1 | JA | G1 seeded library (46 books) + reader fixtures | `57dc75856284` |
| `rd-chrome-hover-edge-w1280-en` | 1C-RD-CHROME | reader | RD-06 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `479c55e3c30d` |
| `rd-chrome-missing-file-w900-en` | 1C-RD-CHROME | reader | RD-17 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `eb8ee19526a2` |
| `rd-chrome-open-error-w900-en` | 1C-RD-CHROME | reader | RD-17 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `606ce4f384e2` |
| `rd-chrome-opening-w900-en` | 1C-RD-CHROME | reader | RD-16 | 900×700 | 900×700 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `b309bcc6de7c` |
| `rd-chrome-tabs-w1280-ja` | 1C-RD-CHROME | reader | RD-03 | 1280×800 | 1280×800 | 1 | JA | G1 seeded library (46 books) + reader fixtures | `9e6a587338d4` |
| `rd-chrome-theme-dark-w1280-en` | 1C-RD-CHROME | reader | RD-01 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `bf99e0138a69` |
| `rd-chrome-theme-sepia-w1280-en` | 1C-RD-CHROME | reader | RD-01 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `41dc3f139294` |
| `rd-chrome-w1280-en` | 1C-RD-CHROME | reader | RD-01 RD-05 RD-06 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `947fb235b01a` |
| `rd-chrome-w1280-ja` | 1C-RD-CHROME | reader | RD-01 RD-03 RD-05 | 1280×800 | 1280×800 | 1 | JA | G1 seeded library (46 books) + reader fixtures | `77223949d923` |
| `rd-epub-bidi-w1280-mix` | 1C-EPUB-PAG | reader | FM-01 FM-21 | 1280×800 | 1280×800 | 1 | MIX | 1C reader seed (the shared 46-book library + six reused conformance fixtures + the generated reader-marks fixture) | `e3dc395e50ab` |
| `rd-epub-cont-w1280-en` | 1C-EPUB-CONT | reader | FM-04 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `0b64a4bb9a52` |
| `rd-epub-cont-w1280-ja` | 1C-EPUB-CONT | reader | FM-04 | 1280×800 | 1280×800 | 1 | JA | G1 seeded library (46 books) + reader fixtures | `1af9f2ac87c0` |
| `rd-epub-fonts-isolation-w1280-en` | 1C-EPUB-PAG | reader | FM-22 | 1280×800 | 1280×800 | 1 | EN | 1C reader seed (the shared 46-book library + six reused conformance fixtures + the generated reader-marks fixture) | `de2f28fe7909` |
| `rd-epub-fonts-w1280-en` | 1C-EPUB-PAG | reader | FM-22 | 1280×800 | 1280×800 | 1 | EN | 1C reader seed (the shared 46-book library + six reused conformance fixtures + the generated reader-marks fixture) | `65476ec703b7` |
| `rd-epub-links-w1280-en` | 1C-EPUB-PAG | reader | FM-01 | 1280×800 | 1280×800 | 1 | EN | 1C reader seed (the shared 46-book library + six reused conformance fixtures + the generated reader-marks fixture) | `f4b8793bde55` |
| `rd-epub-marks-w1280-en` | 1C-EPUB-PAG | reader | FM-01 FM-18 | 1280×800 | 1280×800 | 1 | EN | 1C reader seed (the shared 46-book library + six reused conformance fixtures + the generated reader-marks fixture) | `20c4f5b6b1e7` |
| `rd-epub-mathml-w1280-en` | 1C-EPUB-PAG | reader | FM-23 | 1280×800 | 1280×800 | 1 | EN | 1C reader seed (the shared 46-book library + six reused conformance fixtures + the generated reader-marks fixture) | `728bf423008d` |
| `rd-epub-pag-dpr2-w1280-en` | 1C-EPUB-PAG | reader | FM-01 | 1280×800 | 2560×1600 | 2 | EN | G1 seeded library (46 books) + reader fixtures | `4aeb9d97e47b` |
| `rd-epub-pag-w1280-en` | 1C-EPUB-PAG | reader | FM-01 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `2b29c79d237f` |
| `rd-epub-pag-w1280-ja` | 1C-EPUB-PAG | reader | FM-01 | 1280×800 | 1280×800 | 1 | JA | G1 seeded library (46 books) + reader fixtures | `fd67f3fc8cd9` |
| `rd-epub-table-w1280-en` | 1C-EPUB-PAG | reader | FM-23 | 1280×800 | 1280×800 | 1 | EN | 1C reader seed (the shared 46-book library + six reused conformance fixtures + the generated reader-marks fixture) | `744e65ba76da` |
| `rd-panel-contents-w1280-ja` | 1C-RD-PANEL | reader | RD-07 | 1280×800 | 1280×800 | 1 | JA | G1 seeded library (46 books) + reader fixtures | `4d60dd6408fe` |
| `rd-panel-more-c390-en` | 1C-RD-PANEL | reader | RD-10 | 390×844 | 390×844 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `367ff21d74a0` |
| `rd-panel-more-w1280-en` | 1C-RD-PANEL | reader | RD-10 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `bc490a16562d` |
| `rd-panel-note-editor-w1280-en` | 1C-RD-PANEL | reader | RD-08 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `0bcae12cc539` |
| `rd-panel-saved-place-w1280-en` | 1C-RD-PANEL | reader | RD-08 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `dcb0d4185cbf` |
| `rd-panel-saved-places-empty-w1280-en` | 1C-RD-PANEL | reader | RD-08 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `f81362bca9c7` |
| `rd-panel-search-c390-en` | 1C-RD-PANEL | reader | RD-11 | 390×844 | 390×844 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `b02f79e5096a` |
| `rd-panel-search-w1280-en` | 1C-RD-PANEL | reader | RD-11 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `b94700059fa3` |
| `rd-panel-typography-epub-w1280-en` | 1C-RD-PANEL | reader | RD-09 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `872e21da864b` |
| `rd-panel-typography-pdf-w1280-en` | 1C-RD-PANEL | reader | RD-09 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `a137cf9fde1d` |
| `rd-pdf-cont-w1280-en` | 1C-PDF-CONT | reader | FM-05 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `498b85e2234d` |
| `rd-pdf-fit-width-w1280-en` | 1C-PDF-PAG | reader | FM-02 FM-13 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `af8ecbe69fdc` |
| `rd-pdf-manual-zoom-w1280-en` | 1C-PDF-PAG | reader | FM-02 FM-13 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `75c49c14745a` |
| `rd-pdf-pag-w1280-en` | 1C-PDF-PAG | reader | FM-02 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `a830b406189b` |
| `rd-spread-b720-1131-en` | 1C-SPREAD | reader | FM-09 | 1131×700 | 1131×700 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `17b2bee3c8e7` |
| `rd-spread-b720-1132-en` | 1C-SPREAD | reader | FM-09 | 1132×700 | 1132×700 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `c30014062356` |
| `rd-spread-b720-1133-en` | 1C-SPREAD | reader | FM-09 | 1133×700 | 1133×700 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `692a8b6b0da3` |
| `rd-spread-b720-831-en` | 1C-SPREAD | reader | FM-09 | 831×700 | 831×700 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `fca9def54bb7` |
| `rd-spread-b720-832-en` | 1C-SPREAD | reader | FM-09 | 832×700 | 832×700 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `91acf054ab14` |
| `rd-spread-b720-833-en` | 1C-SPREAD | reader | FM-09 | 833×700 | 833×700 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `fd3be9530df5` |
| `rd-spread-cbz-w1280-en` | 1C-SPREAD | reader | FM-13 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `b5cfb07d106a` |
| `rd-spread-first-w1280-en` | 1C-SPREAD | reader | FM-07 FM-10 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `63c6230fa0f5` |
| `rd-spread-large-font-bf32-w1280-en` | 1C-SPREAD | reader | FM-07 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `90e89d78fc28` |
| `rd-spread-large-font-bf48-w1280-en` | 1C-SPREAD | reader | FM-07 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `49ed53d0bd99` |
| `rd-spread-last-w1280-en` | 1C-SPREAD | reader | FM-10 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `c9f73d125491` |
| `rd-spread-narrow-c390-en` | 1C-SPREAD | reader | FM-08 | 390×844 | 390×844 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `3649a85b950d` |
| `rd-spread-odd-final-w1280-en` | 1C-SPREAD | reader | FM-08 FM-10 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `92c5984f883d` |
| `rd-spread-pdf-last-w1280-en` | 1C-SPREAD | reader | FM-13 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `af17a2e5eebe` |
| `rd-spread-pdf-w1280-en` | 1C-SPREAD | reader | FM-13 | 1280×800 | 1280×800 | 1 | EN | G1 seeded library (46 books) + reader fixtures | `70242a66b662` |
| `rd-spread-w1280-ja` | 1C-SPREAD | reader | FM-07 | 1280×800 | 1280×800 | 1 | JA | G1 seeded library (46 books) + reader fixtures | `5df4462005dd` |

## State derivation and settings

### `rd-cbz-cont-w1280-en`

- Family: 1C-CBZ-CONT · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/comet-courier.cbz` then `Message::ToggleReadingMode` (continuous) (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: cbz `comet-courier.cbz` · continuous · palette light · page 1 of 12 · visible none · spread false · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: Continuous CBZ: the same column behavior as the PDF continuous mode

### `rd-cbz-fit-width-w1280-en`

- Family: 1C-CBZ-PAG · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/comet-courier.cbz` then the paginated raster location page 3 then `Message::SetZoomFitWidth` (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: cbz `comet-courier.cbz` · paginated · palette light · page 3 of 12 · visible 3, 4 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The CBZ fit-width spread: `Message::SetZoomFitWidth` scales the natural page to the reader width, so the page is wider than the fit-page capture of the same page and overflows the viewport height
- Note: `FM-13`'s fit modes: this is the CBZ fit-width half of the row, next to the PDF fit-width and fit-page captures

### `rd-cbz-manual-zoom-w1280-en`

- Family: 1C-CBZ-PAG · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/comet-courier.cbz` then the paginated raster location page 3 then `Message::ZoomIn` from the fit-page baseline (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: cbz `comet-courier.cbz` · paginated · palette light · page 3 of 12 · visible 3, 4 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The CBZ manual-zoom half of `FM-13`: one `Message::ZoomIn` from the fit-page baseline, so the recorded scale is the production arithmetic's own value rather than a chosen number
- Note: The declared scale is re-derived by a regression test from the fixture's page size, so a change in the arithmetic fails the test instead of drifting the manifest

### `rd-cbz-pag-w1280-en`

- Family: 1C-CBZ-PAG · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/comet-courier.cbz` then the paginated raster location page 3 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: cbz `comet-courier.cbz` · paginated · palette light · page 3 of 12 · visible 3, 4 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: Paginated CBZ: the raster pages at the document's natural page size, decoded by the in-process `image` path rather than PDFium
- Note: The CBZ page pair is also the fit-page CBZ spread `FM-13` names: the two pages sit side by side in their own slots

### `rd-chrome-b860-859-en`

- Family: 1C-RD-CHROME · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1, 2 · spread true · available 747×552 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: `B860±` probe: compact chrome at 859 (available reader width 747, still a spread)

### `rd-chrome-b860-860-en`

- Family: 1C-RD-CHROME · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1, 2 · spread true · available 748×552 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: `B860±` probe: the breakpoint itself, where compact chrome ends and the wide header starts (available reader width 748, still a spread)

### `rd-chrome-b860-861-en`

- Family: 1C-RD-CHROME · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1, 2 · spread true · available 749×552 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: `B860±` probe: wide chrome at 861 (available reader width 749, still a spread)

### `rd-chrome-c390-ja`

- Family: 1C-RD-CHROME · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/mizu-no-kioku.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Reader: epub `mizu-no-kioku.epub` · paginated · palette light · page 1 of 3 · visible 1 · spread false · available 278×696 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: Compact chrome below the 860 px breakpoint: the 15 px title truncated at 24 characters, the 28 px edge glyphs and the compact spacing
- Note: `T200` UI text scaling has no Iced counterpart and stays with the accepting package

### `rd-chrome-hover-edge-c390-ja`

- Family: 1C-RD-CHROME · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/mizu-no-kioku.epub` then the paginated EPUB location page 1; the frame is drawn with the pointer delivered at (366, 420), which is inside the enabled next-page edge control, so that control paints the hover state a window would show while the previous-page control stays disabled on the first page
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Pointer: delivered at (366, 420) logical pixels, so the control under it shows its hover state
- Reader: epub `mizu-no-kioku.epub` · paginated · palette light · page 1 of 3 · visible 1 · spread false · available 278×696 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: `RD-06` at the compact configuration: the same enabled next-page control hovered at the 28 px compact glyph and 8 px padding, with the disabled previous-page control beside it
- Note: The pointer position is recorded in the manifest; the same regression test that covers the wide hover capture requires this image to differ from its pointer-free render only inside the edge-control strip

### `rd-chrome-hover-edge-w1280-en`

- Family: 1C-RD-CHROME · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1; the frame is drawn with the pointer delivered at (1256, 420), which is inside the enabled next-page edge control, so that control paints the hover state a window would show while the previous-page control stays disabled on the first page
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Pointer: delivered at (1256, 420) logical pixels, so the control under it shows its hover state
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1, 2 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: `RD-06`'s hover state next to its disabled state: the frame is drawn with the pointer delivered at the enabled next-page edge control, which paints the hover background a window would paint (`theme::reader_edge_button`'s hovered style), while the previous-page control on the first page stays disabled and paints none
- Note: The pointer position is recorded in the manifest; a regression test requires the committed image to differ from the same state without a pointer, and to differ only inside the edge-control strip

### `rd-chrome-missing-file-w900-en`

- Family: 1C-RD-CHROME · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` after its disposable copy is removed: the real missing-file state, restored immediately afterwards so the committed fixture tree stays complete
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader:  `` · paginated · palette light · page 0 of 0 · visible none · spread false · available 788×552 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 0
- Note: A real missing-file state: the disposable copy of the seeded book is removed before `Message::OpenLibraryBook` is dispatched, so the alert, the locate action and the remove action are production output
- Note: The fixture is written back immediately afterwards, so the committed fixture tree and its checksums stay complete

### `rd-chrome-open-error-w900-en`

- Family: 1C-RD-CHROME · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` is started and left in flight; its disposable copy is then overwritten with bytes that are not a document, the production preparation path reports the real failure for those bytes, and that failure is delivered through the production `Message::DocumentOpened { result: Err(..) }` for the in-flight generation. The original bytes are written back immediately afterwards, so the committed fixture tree stays complete
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader:  `` · paginated · palette light · page 0 of 0 · visible none · spread false · available 788×552 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 0
- Note: A real open failure: the disposable copy is overwritten with bytes that are not a document, the production preparation path reports the failure for those bytes, and it is delivered through the production `Message::DocumentOpened { result: Err(..) }` for the in-flight generation, so the alert text is the production document-open error rather than a substituted message
- Note: The fixture is written back immediately afterwards, so the committed fixture tree and its checksums stay complete

### `rd-chrome-opening-w900-en`

- Family: 1C-RD-CHROME · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` with the open task left in flight and `Message::ShowDocumentOpenNotice(generation)` delivered, which is the production timer's own message for the in-flight generation
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader:  `` · paginated · palette light · page 0 of 0 · visible none · spread false · available 788×552 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 0
- Note: The document-opening composition: the 140×200 cover (a real decoded cover handle), the 16 px title and the 13 px label, capped at 320 logical pixels
- Note: The open task is deliberately left unsettled and the production timer's own `ShowDocumentOpenNotice` message for the in-flight generation is delivered: this is the state a window shows while a document opens, not a synthesized one

### `rd-chrome-tabs-w1280-ja`

- Family: 1C-RD-CHROME · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` for library/featured/slow-rivers.epub`, `library/featured/quiet-cartographer.epub`, `library/featured/mizu-no-kioku.epub in order, then `Message::SelectTab(0)`
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1, 2 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 3
- Note: Three documents open: the selected tab keeps the surface + border treatment, the other two stay reachable, and every tab carries its close control
- Note: `RD-04` (decision-11 overflow, automatic active-tab reveal, keyboard close) has no Iced implementation and is not claimed by this capture

### `rd-chrome-theme-dark-w1280-en`

- Family: 1C-RD-CHROME · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then `Message::CycleTheme` until the reader palette is `dark`
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette dark · page 1 of 4 · visible 1, 2 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The reader surface under the dark palette (`theme.rs`); `XA-11`'s mapped Flutter render stays with 2C/5G, this is the Iced reference

### `rd-chrome-theme-sepia-w1280-en`

- Family: 1C-RD-CHROME · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then `Message::CycleTheme` until the reader palette is `sepia`
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette sepia · page 1 of 4 · visible 1, 2 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The reader surface under the sepia palette (`theme.rs`); `XA-11`'s mapped Flutter render stays with 2C/5G, this is the Iced reference

### `rd-chrome-w1280-en`

- Family: 1C-RD-CHROME · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1, 2 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: Wide chrome: the back action, the centred 17 px title, Contents/`Aa`/`⋯`, the 36 px edge glyphs, the 280 px progress bar and the 11 px page-range status, all with every panel closed

### `rd-chrome-w1280-ja`

- Family: 1C-RD-CHROME · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/mizu-no-kioku.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Reader: epub `mizu-no-kioku.epub` · paginated · palette light · page 1 of 3 · visible 1, 2 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: Japanese interface and a Japanese book: the tab label, the header title, the status-bar page wording and the progress label

### `rd-epub-bidi-w1280-mix`

- Family: 1C-EPUB-PAG · state: reader
- State: `Message::OpenLibraryBook` on `repo:crates/shosai-core/tests/fixtures/epub-conformance/bidi.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `bidi.epub` · paginated · palette light · page 1 of 1 · visible 1 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The reused conformance `F5` bidi fixture at the specification's `MIX` configuration: the interface stays English while the document mixes scripts, the right-to-left paragraphs keep their direction (the Hebrew and Arabic runs occupy their logical slots) and the Latin and Japanese runs compose in the page
- Note: Two parts of the row are not visible here. The Hebrew and Arabic runs themselves are blank, because the pinned capture font set has no face for those scripts; and the fixture's authored RTL *list* direction is not preserved, because the Iced list composition is left-to-right. Both are recorded as the partial-coverage reason on `FM-21` and in the known limitations rather than being read as a rendering result

### `rd-epub-cont-w1280-en`

- Family: 1C-EPUB-CONT · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then `Message::ToggleReadingMode` (continuous) (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · continuous · palette light · page 1 of 4 · visible none · spread false · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: Continuous EPUB in English: four chapters in one column, each with its own heading and body text
- Note: The offscreen renderer has no scroll interaction, so the column is captured from its top; `FM-14`'s tile seams are a Flutter/renderer deliverable (`5H-RENDER`) and are not claimed here

### `rd-epub-cont-w1280-ja`

- Family: 1C-EPUB-CONT · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/mizu-no-kioku.epub` then `Message::ToggleReadingMode` (continuous) (no panel open)
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Reader: epub `mizu-no-kioku.epub` · continuous · palette light · page 1 of 3 · visible none · spread false · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: Continuous EPUB: the chapter column with 32 px chapter spacing and 20 px content padding, no page boxes, no per-page titles and no footers

### `rd-epub-fonts-isolation-w1280-en`

- Family: 1C-EPUB-PAG · state: reader
- State: `Message::OpenLibraryBook` on `repo:crates/shosai-core/tests/fixtures/epub-conformance/fonts-isolation.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `fonts-isolation.epub` · paginated · palette light · page 1 of 1 · visible 1 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The reused conformance isolation fixture: its embedded face is used only for the run the document asks for it on, while the heading and every other run keep the interface font (`FM-22`)

### `rd-epub-fonts-w1280-en`

- Family: 1C-EPUB-PAG · state: reader
- State: `Message::OpenLibraryBook` on `repo:crates/shosai-core/tests/fixtures/epub-conformance/fonts.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `fonts.epub` · paginated · palette light · page 1 of 1 · visible 1 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The reused conformance font fixture: four embedded container formats, a bold and an italic face of an embedded family, and the missing/corrupt fallbacks (`FM-22`)
- Note: Embedded faces are document fonts: they stay isolated from the interface fonts the pinned environment registers, which is what the image shows

### `rd-epub-links-w1280-en`

- Family: 1C-EPUB-PAG · state: reader
- State: `Message::OpenLibraryBook` on `repo:crates/shosai-core/tests/fixtures/epub-conformance/links.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `links.epub` · paginated · palette light · page 1 of 2 · visible 1, 2 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The reused conformance link fixture: its anchors and the cross-chapter target page compose inside the page budget, so a reviewer sees what the reader does with the fixture's link shapes
- Note: The fixture's chapter puts its anchors directly under `<main>`, and the parser's inline collector does not carry a block-level anchor's own `href` into its spans, so those anchors render as plain text. The gap is recorded in the known limitations; `FM-01`'s styled-link evidence is `rd-epub-marks-w1280-en`, whose link sits inside a paragraph and renders with the palette's link colour and underline

### `rd-epub-marks-w1280-en`

- Family: 1C-EPUB-PAG · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/reader-marks.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `reader-marks.epub` · paginated · palette light · page 1 of 1 · visible 1 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The generated capture-only fixture: a list, a quote, a styled link and a document image in one page, which is the composition `FM-01` names
- Note: `FM-18`: the specification names `F4` (`conformance.epub`) and `F7` (`mathml.epub`) for this row, but `F4` cannot render under the pinned capture font environment and `F7` carries no document colour, so the colour evidence comes from this generated fixture: its image is filled with one exact colour the chrome never uses, and a regression test requires that colour in the rendered page, so a tinted or monochrome composite fails instead of passing unnoticed
- Note: The fixture deliberately carries no italic on the interface family: the repository's sampler book does, and the pinned capture font environment cannot shape it (see the rich-fixture limitation)

### `rd-epub-mathml-w1280-en`

- Family: 1C-EPUB-PAG · state: reader
- State: `Message::OpenLibraryBook` on `repo:crates/shosai-core/tests/fixtures/epub-conformance/mathml.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `mathml.epub` · paginated · palette light · page 1 of 1 · visible 1 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The reused conformance math fixture: inline and display math compose inside the page budget (`FM-23`)

### `rd-epub-pag-dpr2-w1280-en`

- Family: 1C-EPUB-PAG · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1, 2 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: DPR 2 sharpness subset (specification `D2`): the composition is the DPR 1 capture, only the raster density differs
- Note: `FM-19`/`XA-09` acceptance stays with 6C

### `rd-epub-pag-w1280-en`

- Family: 1C-EPUB-PAG · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 2 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 2 of 4 · visible 1, 2 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: Paginated EPUB: styled headings and body text composed by the production view, the page-number footer and the spread pairing
- Note: The composited page is written as full RGBA; `FM-18` acceptance (document colours survive compositing) is plan 5G's, so the row is recorded as pending for 1C

### `rd-epub-pag-w1280-ja`

- Family: 1C-EPUB-PAG · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/mizu-no-kioku.epub` then the paginated EPUB location page 2 (no panel open)
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Reader: epub `mizu-no-kioku.epub` · paginated · palette light · page 2 of 3 · visible 1, 2 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: Japanese pagination and Japanese interface text in the same capture

### `rd-epub-table-w1280-en`

- Family: 1C-EPUB-PAG · state: reader
- State: `Message::OpenLibraryBook` on `repo:crates/shosai-core/tests/fixtures/epub-conformance/table.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `table.epub` · paginated · palette light · page 1 of 1 · visible 1 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The reused conformance table fixture: table cells and a table image compose inside the page budget (`FM-23`)

### `rd-panel-contents-w1280-ja`

- Family: 1C-RD-PANEL · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/mizu-no-kioku.epub` then the paginated EPUB location page 1 (`contents` open)
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Reader: epub `mizu-no-kioku.epub` · paginated · palette light · page 1 of 3 · visible 1, 2 · spread true · available 868×652 logical · book font 16 px at line spacing 1.6 · panels [contents] · saved places 0 · search matches n/a · tabs 1
- Note: The Contents panel: the 18 px heading, the 11 px subheading and the chapter list, which is Iced's table of contents (there are no saved places yet in this capture)

### `rd-panel-more-c390-en`

- Family: 1C-RD-PANEL · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1 (`more` open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1 · spread false · available 278×612 logical · book font 16 px at line spacing 1.6 · panels [more] · saved places 0 · search matches n/a · tabs 1
- Note: The `⋯` panel in its compact composition: the page row stacks above the actions

### `rd-panel-more-w1280-en`

- Family: 1C-RD-PANEL · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1 (`more` open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1, 2 · spread true · available 1168×594 logical · book font 16 px at line spacing 1.6 · panels [more] · saved places 0 · search matches n/a · tabs 1
- Note: The `⋯` panel in its wide composition: the page input with `of N`, the bookmark toggle, the open-book action and the search toggle on one row

### `rd-panel-note-editor-w1280-en`

- Family: 1C-RD-PANEL · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 2 (`contents+note-editor` open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 2 of 4 · visible 1, 2 · spread true · available 868×652 logical · book font 16 px at line spacing 1.6 · panels [contents] · saved places 1 · search matches n/a · tabs 1
- Note: The saved place with its note editor open (`Message::StartEditNote` on the real bookmark id plus `Message::EditNoteChanged`), which is how a note is written

### `rd-panel-saved-place-w1280-en`

- Family: 1C-RD-PANEL · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 2 (`contents+saved-place` open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 2 of 4 · visible 1, 2 · spread true · available 868×652 logical · book font 16 px at line spacing 1.6 · panels [contents] · saved places 1 · search matches n/a · tabs 1
- Note: One saved place, created by `Message::ToggleBookmark` on the page this capture is on: the entry shows its page label and its edit/delete actions

### `rd-panel-saved-places-empty-w1280-en`

- Family: 1C-RD-PANEL · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1 (`contents` open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1, 2 · spread true · available 868×652 logical · book font 16 px at line spacing 1.6 · panels [contents] · saved places 0 · search matches n/a · tabs 1
- Note: The saved-places empty state: the disposable store carries no bookmark for this capture, and the run clears reader state between captures so the order of the captures cannot change that

### `rd-panel-search-c390-en`

- Family: 1C-RD-PANEL · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1 (`Message::ToggleSearchBar` and the query `the`)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1 · spread false · available 278×524 logical · book font 16 px at line spacing 1.6 · panels [more, search] · saved places 0 · search matches 16 · tabs 1
- Note: The compact search bar, below the compact `⋯` panel that opened it

### `rd-panel-search-w1280-en`

- Family: 1C-RD-PANEL · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1 (`Message::ToggleSearchBar` and the query `the`)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1, 2 · spread true · available 1168×542 logical · book font 16 px at line spacing 1.6 · panels [more, search] · saved places 0 · search matches 16 · tabs 1
- Note: The search bar with real results: the query went through the production debounce and the production search worker, so `n / total`, the previous/next actions and the close control all read from the settled result

### `rd-panel-typography-epub-w1280-en`

- Family: 1C-RD-PANEL · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1 (`typography` open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1, 2 · spread true · available 1168×590 logical · book font 16 px at line spacing 1.6 · panels [typography] · saved places 0 · search matches n/a · tabs 1
- Note: The EPUB typography controls: `A−`/`A+` around the 16 px book-font label and the palette cycle button

### `rd-panel-typography-pdf-w1280-en`

- Family: 1C-RD-PANEL · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/small-atlas.pdf` then the paginated raster location page 1 (`typography` open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: pdf `small-atlas.pdf` · paginated · palette light · page 1 of 4 · visible 1, 2 · spread true · available 1168×590 logical · book font 16 px at line spacing 1.6 · panels [typography] · saved places 0 · search matches n/a · tabs 1
- Note: The PDF/CBZ controls: zoom `−`/`+`, the percentage label and the fit-width/fit-page pair, which replace the EPUB font controls for a non-reflowable document

### `rd-pdf-cont-w1280-en`

- Family: 1C-PDF-CONT · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/small-atlas.pdf` then `Message::ToggleReadingMode` (continuous) (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: pdf `small-atlas.pdf` · continuous · palette light · page 1 of 4 · visible none · spread false · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: Continuous PDF: the page column with 20 px spacing and 20 px padding and its page labels

### `rd-pdf-fit-width-w1280-en`

- Family: 1C-PDF-PAG · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/small-atlas.pdf` then the paginated raster location page 2 then `Message::SetZoomFitWidth` (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: pdf `small-atlas.pdf` · paginated · palette light · page 2 of 4 · visible 1, 2 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The second fit mode of `FM-02`, and the fit-width spread `FM-13` names: `Message::SetZoomFitWidth` on the same page as `rd-pdf-pag-w1280-en`, so the spread fills the reader width instead of fitting inside it
- Note: Manual zoom (the third mode both rows name) is reached by `Message::ZoomIn`/`ZoomOut` from the current fit scale and is recorded as a gap in the package limitations

### `rd-pdf-manual-zoom-w1280-en`

- Family: 1C-PDF-PAG · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/small-atlas.pdf` then the paginated raster location page 2 then `Message::ZoomIn` from the fit-page baseline (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: pdf `small-atlas.pdf` · paginated · palette light · page 2 of 4 · visible 1, 2 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The third fit mode `FM-02` and `FM-13` name: one `Message::ZoomIn` from the fit-page baseline, recorded as the production arithmetic's own scale
- Note: The declared scale is re-derived by a regression test from the fixture's page size, so a change in the arithmetic fails the test instead of drifting the manifest

### `rd-pdf-pag-w1280-en`

- Family: 1C-PDF-PAG · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/small-atlas.pdf` then the paginated raster location page 2 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: pdf `small-atlas.pdf` · paginated · palette light · page 2 of 4 · visible 1, 2 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: Paginated PDF: the raster pages produced by the native PDFium backend at the fit-page scale, with the page label in the status bar
- Note: The generated PDF draws shapes only, so the raster does not depend on host fonts; the native PDFium identity is recorded in the manifest as run metadata

### `rd-spread-b720-1131-en`

- Family: 1C-SPREAD · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1 (`contents` open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1 · spread false · available 719×552 logical · book font 16 px at line spacing 1.6 · panels [contents] · saved places 0 · search matches n/a · tabs 1
- Note: `B720±` probe with the bookmarks panel open: available reader width 719 after the 300 px panel, so the same single-page side of the threshold is reached at a wider client

### `rd-spread-b720-1132-en`

- Family: 1C-SPREAD · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1 (`contents` open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1, 2 · spread true · available 720×552 logical · book font 16 px at line spacing 1.6 · panels [contents] · saved places 0 · search matches n/a · tabs 1
- Note: `B720±` probe with the bookmarks panel open: available reader width 720, the threshold itself

### `rd-spread-b720-1133-en`

- Family: 1C-SPREAD · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1 (`contents` open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1, 2 · spread true · available 721×552 logical · book font 16 px at line spacing 1.6 · panels [contents] · saved places 0 · search matches n/a · tabs 1
- Note: `B720±` probe with the bookmarks panel open: available reader width 721, a spread

### `rd-spread-b720-831-en`

- Family: 1C-SPREAD · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1 · spread false · available 719×552 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: `B720±` probe, panels closed: available reader width 719, below the spread threshold, so one page fills the row
- Note: The client width is also below the 860 px reader breakpoint, so this probe exercises compact chrome with a single page

### `rd-spread-b720-832-en`

- Family: 1C-SPREAD · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1, 2 · spread true · available 720×552 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: `B720±` probe, panels closed: available reader width 720, the threshold itself, where the spread starts

### `rd-spread-b720-833-en`

- Family: 1C-SPREAD · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1, 2 · spread true · available 721×552 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: `B720±` probe, panels closed: available reader width 721, still a spread

### `rd-spread-cbz-w1280-en`

- Family: 1C-SPREAD · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/comet-courier-02.cbz` then the paginated raster location page 3 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: cbz `comet-courier-02.cbz` · paginated · palette light · page 3 of 3 · visible 3 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The CBZ spread with an odd total: three pages, so the final spread shows the last page alone, without a blank page or a repeated page

### `rd-spread-first-w1280-en`

- Family: 1C-SPREAD · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/quiet-cartographer.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `quiet-cartographer.epub` · paginated · palette light · page 1 of 3 · visible 1, 2 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The first spread: two distinct consecutive pages side by side, with no reserved slot before them

### `rd-spread-large-font-bf32-w1280-en`

- Family: 1C-SPREAD · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then `Message::FontSizeUp` until the book font is 32 px; comparison only (Iced has no readability fallback)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1, 2 · spread true · available 1168×652 logical · book font 32 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: Comparison only for decision 12: Iced keeps the width-only 720 px spread rule at a 32 px book font and never falls back to one column for readability, so this image cannot evidence `FM-11` or `FM-12`; acceptance is owned by 5A/5B/5H and `FM-11` stays pending in this package's matrix
- Note: The row it renders is `FM-07`: the wide paginated EPUB spread, here at a 32 px book font

### `rd-spread-large-font-bf48-w1280-en`

- Family: 1C-SPREAD · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then `Message::FontSizeUp` until the book font is 48 px; comparison only (Iced has no readability fallback)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 8 · visible 1, 2 · spread true · available 1168×652 logical · book font 48 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: Comparison only, as the 32 px capture: the book font stays at its chosen size and Iced still forms a spread, which is exactly the behavior decision 12 replaces for the Flutter reader
- Note: The row it renders is `FM-07`: the wide paginated EPUB spread, here at a 48 px book font

### `rd-spread-last-w1280-en`

- Family: 1C-SPREAD · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 3 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 3 of 4 · visible 3, 4 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The last spread of an even page count: the final pair, neither page orphaned and neither repeated

### `rd-spread-narrow-c390-en`

- Family: 1C-SPREAD · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/slow-rivers.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `slow-rivers.epub` · paginated · palette light · page 1 of 4 · visible 1 · spread false · available 278×696 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: Narrow single-page mode: one page fills the row with no reserved second slot (available reader width 278)

### `rd-spread-odd-final-w1280-en`

- Family: 1C-SPREAD · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/quiet-cartographer.epub` then the paginated EPUB location page 3 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: epub `quiet-cartographer.epub` · paginated · palette light · page 3 of 3 · visible 3 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: An odd page count: the final spread shows exactly one page in its half-width slot, no blank page is inserted and the last page is not repeated

### `rd-spread-pdf-last-w1280-en`

- Family: 1C-SPREAD · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/field-notes.pdf` then the paginated raster location page 2 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: pdf `field-notes.pdf` · paginated · palette light · page 2 of 2 · visible 1, 2 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The final raster spread of an even total: two pages, so the pair is complete and the last page is shown next to the one before it rather than alone

### `rd-spread-pdf-w1280-en`

- Family: 1C-SPREAD · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/small-atlas.pdf` then the paginated raster location page 1 (no panel open)
- Settings: harness defaults (language en-US, add behavior ask, reader defaults paginated/light/16 px/1.6/fit page)
- Reader: pdf `small-atlas.pdf` · paginated · palette light · page 1 of 4 · visible 1, 2 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The PDF spread: two consecutive raster pages, the first pair of a four-page book, each drawn in its own slot

### `rd-spread-w1280-ja`

- Family: 1C-SPREAD · state: reader
- State: `Message::OpenLibraryBook` on `library/featured/kaze-no-mukougawa.epub` then the paginated EPUB location page 1 (no panel open)
- Settings: language=ja (persisted by `Message::SelectLanguage`)
- Reader: epub `kaze-no-mukougawa.epub` · paginated · palette light · page 1 of 2 · visible 1, 2 · spread true · available 1168×652 logical · book font 16 px at line spacing 1.6 · panels [] · saved places 0 · search matches n/a · tabs 1
- Note: The Japanese spread: two consecutive Japanese pages with the Japanese interface

## Matrix coverage

Covered by a capture in this set:

| Row | Captures |
| --- | --- |
| RD-01 | `rd-chrome-b860-860-en` `rd-chrome-b860-861-en` `rd-chrome-theme-dark-w1280-en` `rd-chrome-theme-sepia-w1280-en` `rd-chrome-w1280-en` `rd-chrome-w1280-ja` |
| RD-02 | `rd-chrome-b860-859-en` `rd-chrome-c390-ja` |
| RD-03 | `rd-chrome-tabs-w1280-ja` `rd-chrome-w1280-ja` |
| RD-05 | `rd-chrome-w1280-en` `rd-chrome-w1280-ja` |
| RD-06 | `rd-chrome-c390-ja` `rd-chrome-hover-edge-c390-ja` `rd-chrome-hover-edge-w1280-en` `rd-chrome-w1280-en` |
| RD-07 | `rd-panel-contents-w1280-ja` |
| RD-08 | `rd-panel-note-editor-w1280-en` `rd-panel-saved-place-w1280-en` `rd-panel-saved-places-empty-w1280-en` |
| RD-09 | `rd-panel-typography-epub-w1280-en` `rd-panel-typography-pdf-w1280-en` |
| RD-10 | `rd-panel-more-c390-en` `rd-panel-more-w1280-en` |
| RD-11 | `rd-panel-search-c390-en` `rd-panel-search-w1280-en` |
| RD-16 | `rd-chrome-opening-w900-en` |
| RD-17 | `rd-chrome-missing-file-w900-en` `rd-chrome-open-error-w900-en` |
| FM-01 | `rd-epub-bidi-w1280-mix` `rd-epub-links-w1280-en` `rd-epub-marks-w1280-en` `rd-epub-pag-dpr2-w1280-en` `rd-epub-pag-w1280-en` `rd-epub-pag-w1280-ja` |
| FM-02 | `rd-pdf-fit-width-w1280-en` `rd-pdf-manual-zoom-w1280-en` `rd-pdf-pag-w1280-en` |
| FM-03 | `rd-cbz-fit-width-w1280-en` `rd-cbz-manual-zoom-w1280-en` `rd-cbz-pag-w1280-en` |
| FM-04 | `rd-epub-cont-w1280-en` `rd-epub-cont-w1280-ja` |
| FM-05 | `rd-pdf-cont-w1280-en` |
| FM-06 | `rd-cbz-cont-w1280-en` |
| FM-07 | `rd-spread-first-w1280-en` `rd-spread-large-font-bf32-w1280-en` `rd-spread-large-font-bf48-w1280-en` `rd-spread-w1280-ja` |
| FM-08 | `rd-spread-narrow-c390-en` `rd-spread-odd-final-w1280-en` |
| FM-09 | `rd-spread-b720-1131-en` `rd-spread-b720-1132-en` `rd-spread-b720-1133-en` `rd-spread-b720-831-en` `rd-spread-b720-832-en` `rd-spread-b720-833-en` |
| FM-10 | `rd-spread-first-w1280-en` `rd-spread-last-w1280-en` `rd-spread-odd-final-w1280-en` |
| FM-13 | `rd-cbz-fit-width-w1280-en` `rd-cbz-manual-zoom-w1280-en` `rd-cbz-pag-w1280-en` `rd-pdf-fit-width-w1280-en` `rd-pdf-manual-zoom-w1280-en` `rd-spread-cbz-w1280-en` `rd-spread-pdf-last-w1280-en` `rd-spread-pdf-w1280-en` |
| FM-18 | `rd-epub-marks-w1280-en` |
| FM-21 | `rd-epub-bidi-w1280-mix` |
| FM-22 | `rd-epub-fonts-isolation-w1280-en` `rd-epub-fonts-w1280-en` |
| FM-23 | `rd-epub-mathml-w1280-en` `rd-epub-table-w1280-en` |

Covered by the manifest itself (provenance, no image):

| Row | Satisfied by |
| --- | --- |
| XA-10 | satisfied by `manifest.json` with `captures.sha256`, `fixtures.sha256` and the README rather than by an image |

Pending, not covered by Iced captures (with owner and reason):

| Row | Owner | Reason |
| --- | --- | --- |
| RD-04 | pending | 4B — decision-11 tab overflow (active-tab reveal, keyboard close, readable width floor) has no Iced implementation |
| RD-12 | pending | 4D — selection and annotation actions are RFD 6 / retained Flutter authority, recorded in the 1C non-Iced authority record instead of an Iced capture |
| RD-13 | pending | 4B — panel exclusivity is behavioral (`WT`): an Iced capture of the same state would only duplicate the open-panel captures |
| RD-14 | pending | 4B — keyboard reachability and focus visibility are Flutter-owned (`WT`) |
| RD-15 | pending | 4D — large-text and palette inspection of the Flutter components is local evidence |
| FM-11 | pending | 5H — decision-12 readability fallback has no Iced implementation; the large-font captures are comparison images only |
| FM-12 | pending | 5H — the fallback boundary and durable-location preservation are `WT` + `5H-RENDER` |
| FM-14 | pending | 5H — tiled continuous seams are a Flutter/renderer deliverable; Iced continuous is a single chapter column with no tiled render |
| FM-15 | pending | 5H — mode-switch position preservation is behavioral (`WT`) |
| FM-16 | pending | 5I — EPUB cross-fragment selection is RFD 6 authority, not an Iced capture |
| FM-17 | pending | 5I — PDF page-local selection is RFD 6 authority |
| FM-19 | pending | 6C — DPR 2 sharpness acceptance is `6C-A11Y`; the 1C DPR 2 capture is the Iced reference |
| FM-20 | pending | 5J — resource-rejection distinguishability is behavioral (`WT`) |

## Captures that intentionally share pixels

None: every capture in this set renders a different image, and the capture run fails
when two captures are byte-identical without a declared alias.

## Fixtures

Generated in-repo: every archive and image is produced by the deterministic generator above, no third-party content is embedded, and the generator reads no clock, locale or random source. The reused conformance book keeps its own documented redistribution statement.

Generated files: 59 (all hashed in `fixtures.sha256` and in `manifest.json`). The
dangling-symlink discovery-failure fixture could be created on this platform: true.

| Reused fixture | SHA-256 | Provenance | Purpose |
| --- | --- | --- | --- |
| `crates/shosai-core/tests/fixtures/epub-conformance/bidi.epub` | `5af9e82d15fa` (verified) | crates/shosai-core/tests/fixtures/epub-conformance/README.md + SHA256SUMS (documented redistribution-safe) | bidi and mixed-script composition plus a content list (`FM-01`, `FM-21`) |
| `crates/shosai-core/tests/fixtures/epub-conformance/fonts.epub` | `bcd605900627` (verified) | crates/shosai-core/tests/fixtures/epub-conformance/README.md + SHA256SUMS (documented redistribution-safe) | embedded document fonts across four container formats (`FM-22`) |
| `crates/shosai-core/tests/fixtures/epub-conformance/fonts-isolation.epub` | `0c991567a524` (verified) | crates/shosai-core/tests/fixtures/epub-conformance/README.md + SHA256SUMS (documented redistribution-safe) | embedded font isolation from the interface fonts (`FM-22`) |
| `crates/shosai-core/tests/fixtures/epub-conformance/links.epub` | `bb899a2d67b7` (verified) | crates/shosai-core/tests/fixtures/epub-conformance/README.md + SHA256SUMS (documented redistribution-safe) | inline and block links (`FM-01`) |
| `crates/shosai-core/tests/fixtures/epub-conformance/mathml.epub` | `03f1978d9ea5` (verified) | crates/shosai-core/tests/fixtures/epub-conformance/README.md + SHA256SUMS (documented redistribution-safe) | inline and display math (`FM-23`) |
| `crates/shosai-core/tests/fixtures/epub-conformance/table.epub` | `9f54aac1fe40` (verified) | crates/shosai-core/tests/fixtures/epub-conformance/README.md + SHA256SUMS (documented redistribution-safe) | tables and table images (`FM-23`) |

## Fonts

| Role | SHA-256 |
| --- | --- |
| InterVariable.ttf (type.ui.family.latin) | `4989b125924991b90d05b2d16e0e388c48f7d5bb8b30539bbf9c755278d0ccaf` |
| NotoSansJP-Variable.ttf (type.ui.family.japanese) | `c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f` |
| math font (type.math.family) | `4989b125924991b90d05b2d16e0e388c48f7d5bb8b30539bbf9c755278d0ccaf` |

## Non-Iced authority (rows this package does not capture)

- RD-12 / FM-16 / FM-17 — selection and highlighting: authority is RFD 6 (`rfd/0006/README.adoc`) plus the retained Flutter implementation (`flutter/lib/reader/view_selection.dart`), owned by 4D and 5I. Iced has no production interactive selection, so no 1C image exists for these rows and none is fabricated.
- RD-04 — tab overflow (decision 11): authority is the owner decision recorded in `docs/flutter-ui-restoration-plan.md`; Iced supplies only a horizontally scrollable strip with no automatic active-tab reveal, no keyboard close and no readable-width floor.
- RD-14 / RD-15 / FM-19 — keyboard reachability, large-text and DPR-2 inspection of the Flutter components: authority is the retained Flutter implementation and the plan's accessibility requirements; Iced has no text scaling.
- FM-11 / FM-12 — decision-12 readability fallback: authority is the owner decision and the `5A` rule calibrated in `5B`; Iced applies a width-only 720 px spread rule and the large-font captures here are comparison images only.
- FM-14 / FM-15 — tiled continuous seams and mode-switch position preservation: authority is the plan's continuous-layout requirements; Iced continuous is a single chapter column with no tiled render.
- FM-20 — resource rejection is distinguishable from a rendering defect: authority is the plan's 5J acceptance; the limits live in the shared core and are behavioral.
- FM-18 / FM-21 / FM-22 / FM-23 — document colours, bidi, embedded fonts, tables and math are captured over the reused conformance fixtures that render under the pinned font environment; acceptance stays with 5G/5C/5D, and the two fixtures that cannot render are recorded in the limitations rather than replaced by a fabricated image.

## Known limitations

- Iced has no production interactive selection or highlighting: `RD-12`, `FM-16` and `FM-17` are recorded as RFD 6 / retained-Flutter authority in the 1C non-Iced authority record and `docs/reference-captures.md`, never fabricated as an Iced capture.
- Iced applies a width-only 720 px spread rule and has no decision-12 readability fallback: the `BF32`/`BF48` captures are comparison images only and `FM-11`/`FM-12` stay with 5A/5B/5H.
- The offscreen renderer has no scroll interaction and the application exposes no message that scrolls the reader: continuous captures show the chapter/page column from its top and the paginated captures are reached by the production page-navigation messages. Tiled continuous seams (`FM-14`) are a Flutter/renderer deliverable.
- Iced has no text scaling (`T200`) and no decision-11 tab overflow: `RD-04`, `RD-14` and `RD-15` have no Iced counterpart and stay with 4B/4D.
- The document-opening capture delivers the production timer's own `ShowDocumentOpenNotice(generation)` message for the in-flight generation, because the offscreen run cannot wait on a real window's 200 ms timer without also completing the open it is capturing; the state it shows is the production opening composition.
- The missing-file and open-error captures need a real failure, so they remove (respectively overwrite) the disposable copy of one seeded fixture and write the original bytes back immediately afterwards; the committed fixture tree and its checksums stay complete, and the disposable root is the run's own.
- Two of the repository's conformance fixtures cannot render under the pinned capture font environment: `conformance.epub` and `css-cascade.epub` both style `font-style: italic` on the default family, which has no italic face in the pinned set, and the text stack panics (`no default font found`) instead of falling back to the family's upright face. The other twelve conformance fixtures render and are the ones the rich captures use; the trigger is a production behavior (only the application fonts are registered), and the fallback gap itself belongs with the renderer owner rather than being papered over here.
- The generated PDF fixtures draw shapes only (no page text), because PDFium resolves fonts for unembedded text by scanning the host font directories and does not follow `FONTCONFIG_FILE`; the native PDFium that rasterized the pages is recorded in `environment.pdfium` as run metadata, so a different build can render different pixels.
- Rendering is in-process software rasterization, not a compositor screenshot: window decorations, native menus, toasts and animations are outside the capture, and the disposable data root path is visible in application text that names a real path.
- Every reader capture uses a viewport the composition fits in, because the renderer has no scroll interaction: the reader chrome is captured at `W1280`/`W900`/`C390` and at the documented `B860±`/`B720±` probe widths. The layout rules, the theme and the composition are unchanged; only the window is the size the probe names. The zoom captures are the deliberate exceptions: `rd-pdf-fit-width-w1280-en`, `rd-cbz-fit-width-w1280-en`, `rd-pdf-manual-zoom-w1280-en` and `rd-cbz-manual-zoom-w1280-en` all scale the page past the viewport height, so those captures show the overflow and the vertical scrollbar instead of a page that fits.
- The rich captures open from package 1C's own base seed (the shared library plus the reused conformance fixtures and the generated marks fixture) so the shared seed's order, and therefore package 1B's evidence, is untouched. The marks fixture is generated for these captures and carries no italic on the interface family, which is why it can render where `conformance.epub` cannot.
- An anchor that is itself a block-level child of a block container loses its own `href`: the parser's inline collector applies a link only to the spans *inside* an `a` element, not to the anchor's own block. `links.epub`'s chapter puts its anchors directly under `main`, which is why `rd-epub-links-w1280-en` shows their text without the link colour or underline; the same anchor inside a paragraph (`rd-epub-marks-w1280-en`) or inside a table cell (`rd-epub-table-w1280-en`) keeps its link.
- The pinned capture font set (Inter, NotoSansJP and the math font, with a fontconfig that names an empty directory) covers Latin, Japanese and the math glyphs only. `FM-21`'s Hebrew and Arabic runs in `bidi.epub`, and the emoji in its mixed line, therefore render blank in `rd-epub-bidi-w1280-mix`: the capture shows the fixture's right-to-left paragraphs and its Latin/Japanese runs, not its Hebrew or Arabic shaping. The fixture's authored RTL list direction is not preserved either, because the Iced list composition is left-to-right (`app/epub_view.rs`), which is why `FM-21` is recorded as a partially covered row. Evidencing the missing halves needs a Hebrew/Arabic face in the capture font set and an RTL-aware list composition, which are renderer/capture-contract changes and owner decisions rather than something this package may do on its own.
- The shared EPUB style model carries no colour field, so document text is painted with the reader palette and no capture can show a CSS text colour: `FM-18`'s Iced reference is the document *image* path (`rd-epub-marks-w1280-en`), where the document's own pixels survive composition. A document text colour is renderer work that belongs with 5G, not something a capture here can evidence.
- Document images compose only where the parser keeps an image node: a block-level `img` and an image inside a table cell render, while an `img` inside a paragraph is dropped by the inline collector (the paragraph keeps its text only) and a missing resource never reaches the page. `nested-image.epub`'s paragraph-inline image and its missing-image fallback are therefore not composed; the gap is recorded here rather than hidden by a fabricated state.
