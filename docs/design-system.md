# Design system

Shōsai (書斎, "the study") is a reader for EPUB and PDF on desktop, tablet and phone. This document is how it looks and speaks: one reading experience whatever the format or the screen. It serves [RFD 7](../rfd/0007/README.adoc), the MVP proposal, and follows [typography.md](typography.md) for fonts.

## Where it lives

| Path | Role |
| --- | --- |
| `docs/design-system.md` | The rules and words (this file). |
| `docs/design-system/tokens.json` | The tokens: colour, type, space, radius, elevation and layout sizes, each with its use. Edit this file only. |
| `docs/design-system/tokens.css` | CSS custom properties generated from `tokens.json` by `scripts/generate-design-system-css.py`. |
| `docs/design-system/components.css` | The reference styling of every component (`sh-*` classes). |
| `docs/design-system/components/*.html` | One preview per component, in both app themes. |
| `docs/design-system/icons/*.svg` | The Lucide glyphs the components use. |
| `docs/design-system/index.html` | The development viewer. |

### Viewing it in development

```sh
make design-system          # serves http://127.0.0.1:8765/docs/design-system/
make design-system-css      # regenerate tokens.css after editing tokens.json
make check-design-system-css
```

The viewer renders the foundations straight from `tokens.json` and shows every component preview, with a switch between the light and dark app themes. It serves the repository root on localhost so fonts and the app icon load from `assets/`. Set `DESIGN_SYSTEM_PORT` to use another port. `make test-scripts` checks that `tokens.css` matches its source and that every preview the viewer lists exists.

The page-spread preview loads the full Noto Serif JP from Google Fonts for its Japanese pages, because the repository bundles only the 書 subset of that family.

### Relationship to the application tokens

`assets/theme/tokens.json` remains the source the Iced and Flutter frontends render from (see [assets/theme/README.md](../assets/theme/README.md)). This system started from those values and is the design target for the MVP. Moving the applications onto it, including the new page-theme, highlight and spacing tokens, is MVP implementation work and goes through the application token source and its tests, never by reading `docs/design-system/` at runtime.

### Decisions

Recorded 2026-10-14:

- The accent stays the application's slate (`#4d5e86`). The app icon's vermilion marks only the reader's own bookmarks. The website's green (`#275A47`) is a separate decision.
- `ink-muted` darkens to `#625F57`. The repository's `#726F67` falls to 3.9:1 on the tab strip; the new value holds 4.5:1 on every chrome ground.
- Phones in portrait show one page; desktop and tablet in landscape show two by default.

## Principles

1. **The page is the product.** Chrome is quiet, neutral and out of the way. Colour lives on the page (highlights, links) and in one accent.
2. **Format is metadata, not a mode.** EPUB and PDF get the same controls in the same places. A small badge is the only sign of the format.
3. **Layout adapts, behaviour does not.** Panels become sheets and the tab strip becomes a switcher; gestures, words and outcomes stay the same.
4. **The book keeps its voice.** EPUB fonts and writing direction are honoured; PDF pages keep their appearance. Shōsai never restyles a book's words with its own fonts.
5. **Peek before you jump, and always a way back.** Every jump records where it left from.

## Voice and words

Shōsai speaks like a well-made book's front matter: plain, exact and brief.

- **Sentence case** everywhere: *Page note*, *All books*, *Display settings*.
- **Buttons are verbs** that name the outcome: *Go to*, *Back to page 61*, *Add note*, *Delete note*. Never *OK*, *Submit* or *Click here*.
- **Places use the reader's terms**, in one order: section, then page, then percentage. `Chapter IV · page 104`, `21% · pages 104–105 of 502`. EPUB and PDF both say "page".
- **Typography in copy**: curly quotes and apostrophes (’), an en dash for ranges (104–105), a middle dot between facts (·), real ellipses (…). No exclamation marks, no emoji.
- **Quote the book exactly**, including its spelling and punctuation (*favourable*, ‘Beagle’).
- **Empty states say what to do**: *No notes yet. Select text to highlight it, or add a note to this page.*
- **Errors say what happened and what to try**: *This PDF is password-protected. Enter the password to open it.*
- **Counts agree with their number**: *1 note*, *12 notes*.

| Write | Not |
| --- | --- |
| Back to page 61 | Back |
| 12 notes | 12 Note(s) |
| Pages re-render at each zoom, so text stays sharp. | High-DPI rendering enabled! |
| Remove from library | Delete |

Japanese UI copy follows the same rules: plain form, no decorative symbols, and full-width punctuation only inside Japanese text.

## Colour

Three layers, each with its own tokens. Never mix their roles. Every value, with its use, is in `tokens.json` and on the viewer's Colour page.

### Chrome

The app frame in light and dark themes: `canvas` (window ground), `surface` (toolbar, cards, menus), `surface-sunken` (the reading stage), `chrome` (panels and sheets), `tabstrip`, `hover`, `line`, `line-strong`, `ink` and `ink-muted`.

- Text is `ink`, or `ink-muted` for secondary text. Both hold 4.5:1 on every chrome ground in both themes.
- `line` is decorative. A control that must be seen (inputs, secondary buttons) uses `line-strong`, which holds 3:1.
- `control-raised` lifts the chosen segment of a segmented control; in dark it is lighter than `surface` so the choice still reads.
- `scrim` dims the page behind slide-over panels and sheets.

### Accent and brand

- `accent` is Shōsai slate, the one interactive colour: primary buttons, selected states (`accent-soft` with `on-accent-soft`), focus rings, progress, the current note. One primary button per surface.
- `vermilion` is the red of the app icon's spine. It marks only the reader's own marks: a filled bookmark and bookmark ticks on the progress track. Never a button, never an error.
- `brand-navy`, `brand-charcoal`, `brand-cream` and `brand-gold` come from the app icon. They appear in the 書 mark, generated covers and marketing, never in controls.
- `success`, `warning` and `danger` always come with a word or an icon. `warning` is 4.1:1 on `surface` in light, so warning text is set in `ink` beside a `warning` icon.
- `inverse` capsules (back pill, selection toolbar) stay dark in both app themes so they stand off any page theme.

### Pages

Page themes are separate from the app theme: a dark app can show a Paper page.

| Theme | Ground | Ink | Links |
| --- | --- | --- | --- |
| Paper | `page-paper` | `page-paper-ink` | `page-paper-link` |
| Sepia | `page-sepia` | `page-sepia-ink` | `page-sepia-link` |
| Night | `page-night` | `page-night-ink` | `page-night-link` |

Highlights use the `hl-*` fills (yellow, green, blue, pink, purple) at 40% so ink stays legible on every page theme; the matching solid `swatch-*` tokens draw swatches and note dots. `selection` is the live drag selection, `search-hit` and `search-current` mark matches on the page, and `mark` marks matched words in the chrome's result lists. Highlight colours carry no meaning of their own.

## Typography

Follow [typography.md](typography.md). Three roles, never interchanged:

| Role | Family token | Faces | Use |
| --- | --- | --- | --- |
| Interface | `--font-ui` | Inter, Noto Sans JP | Every control, label, panel, list and screen title |
| Editorial | `--font-editorial` | Source Serif 4, Noto Serif JP | The wordmark, empty-state headlines, generated covers, and quoted book text in notes, peeks and search |
| Book | `--font-book` | The book's own fonts, else Source Serif 4 and Noto Serif JP | EPUB content only. PDFs keep their embedded fonts |

- Interface styles: `ui-title` 20/26, `ui-heading` 16/22, `ui-body` 14/20, `ui-control` 13/18, `ui-caption` 12/16, `ui-label` 11/14 uppercase, `ui-badge` 10/12. Weights 400, 500 and 600 only.
- Editorial styles: `ed-display` 32/38, `ed-wordmark` 20/24, `ed-quote` 15/23.
- Book styles: `book-body` 19/31 and `book-body-ja` 20/38 are the defaults when a book sets none; the text-size control scales them from 70% to 160%. `book-chapter` is the fallback chapter label; `book-folio` sets running heads and folios at 60% of the page ink.
- Never synthesize bold or italic. Set figures in places and counts with `font-variant-numeric: tabular-nums`.
- `ui-label` is for Latin text. Japanese labels use `ui-caption` without letter spacing.

## Space, size and layout

Spacing runs on a 4 px base: `space-1` 4, `space-2` 8, `space-3` 12, `space-4` 16, `space-5` 24, `space-6` 32, `space-7` 48. Card padding is `space-3`; sheet padding and phone gutters `space-4`; the reading stage `space-5`.

| Token | Value | Use |
| --- | --- | --- |
| `control-height` | 32 px | Buttons and fields with a pointer |
| `touch-target` | 44 px | Every control on tablet and phone |
| `tabstrip-height` | 44 px | Desktop and tablet tab strip |
| `toolbar-height` | 48 px | Reader toolbar (56 px with touch targets) |
| `statusbar-height` | 36 px | Status line under the page |
| `panel-width` | 360 px | Docked notes panel |
| `spread-min-width` | 720 px | Narrowest stage that shows two pages |
| `measure` | 36em | Widest EPUB text column |

Layouts by width: **phone** below 600 px (one page, sheets, tab switcher), **tablet** 600–1199 px (tab strip, slide-over panels, two pages in landscape), **desktop** 1200 px and up (docked panels, two pages).

Radii: `radius-xs` 2 (pages, highlights, covers), `radius-sm` 6 (buttons, tabs), `radius-md` 10 (cards, popovers, peeks), `radius-lg` 16 (sheet tops). Capsules are fully round.

Elevation is four shadows per theme: `shadow-page` for pages on the stage, `shadow-cover` for library covers, `shadow-menu` for popovers and capsules, `shadow-modal` for search, peeks and sheets. Borders separate everything else.

## Reading surfaces

The page is set like print.

- **Two pages by default** on desktop and tablet in landscape whenever the stage is at least `spread-min-width` wide; **one page** on phones and in portrait. The reader can choose one or two in Display settings, for EPUB and PDF alike.
- **No clipped lines.** Text flows from page to page and breaks at real line starts, so a page holds whole lines only and leftover space at the foot is less than one line. A paragraph that crosses a page continues without an indent, and its last line on the earlier page is justified.
- **Justified text is hyphenated**, so narrow phone pages do not open wide gaps between words. A hyphenated word never splits across a page turn.
- **Chapter openings** drop the running head and sink the title. Other pages carry a running head and a centred folio in `book-folio`.
- **EPUB page numbers** are Shōsai's own pagination at the current size and margins; the same numbers appear in the status line, notes and search results.
- **The book's direction.** Right-to-left books turn leftward with the first page on the right; vertical Japanese keeps `vertical-rl`. Undeclared books read horizontally. There is no override.
- **PDF stays the PDF.** Pages re-render at the current zoom so text is sharp on any screen; on phones they fit the width. Night inverts page luminance.

Layout, pagination and durable anchors are computed in Rust; Flutter renders the laid-out pages (see [flutter-architecture.md](flutter-architecture.md)).

## Components

Each component has a preview in `docs/design-system/components/` and its reference styling in `components.css`. The consumer of a component supplies its content and handlers; the component never reaches into reader state itself.

### Actions

**Button.** One primary, one secondary and one quiet style, plus states.

| Class | Use |
| --- | --- |
| `sh-btn--primary` | The one action a surface exists for: **Go to** in a reference peek, **Save** in a note editor. At most one per surface. |
| `sh-btn--secondary` | The alternative beside a primary (**Cancel**), and standalone actions that need a visible boundary. Border `line-strong`. |
| `sh-btn` (quiet) | Toolbar and panel actions. Fill appears on hover. |
| `sh-btn--selected` | A toggle that is on (the Notes panel). `accent-soft` with `on-accent-soft` and `aria-pressed="true"`. |
| `sh-btn--icon` | Icon-only and square. Needs an `aria-label` and a tooltip with the same words. |
| `sh-btn--touch` | 44 px target for tablet and phone; icons grow to 20 px. |
| `sh-btn--danger` | Destructive, always a word (**Delete note**), never icon-only. |

`sh-count` inside a toggle shows how many items it holds; hide it at zero. Labels are verbs in sentence case with no trailing ellipsis unless the button opens a dialog that asks for more.

**SegmentedControl.** Two to four exclusive views of the same content: scope (**This book** / **All books**), pages (**One** / **Two**), search filters (**Everything** / **Text** / **Notes**). Options are short nouns; an icon may lead when it carries the meaning. The chosen option is raised on `control-raised` with `shadow-menu`. Each option is a `button` with `aria-pressed` inside a `role="group"` with an `aria-label`. Never put an action in a segmented control.

**FormatBadge.** The format in capitals (`EPUB`, `PDF`) in `ui-badge` on `surface-sunken`, beside a title in tabs, library rows, search results and note cards. It never sits next to a control, is never colour-coded, and is left out where one book is in view and the title already identifies it.

### Navigation

**TabStrip** (desktop and tablet). The Iced app's tab model carried forward.

1. The library tab is pinned first, icon only, and cannot be closed or moved.
2. Book tabs show the format badge, the title truncated with an ellipsis, and a close button. Tabs are 220 px and shrink evenly to 120 px; past that the strip scrolls.
3. **Open a book** (`plus`) follows the last tab.

The selected tab joins the toolbar below it; unselected tabs sit on `tabstrip` in `ink-muted`. The close button shows on hover and on the selected tab, and always on touch. Middle-click closes; closing the selected tab selects the one to its right, else its left. Tabs reorder by dragging and survive relaunch.

**TabSwitcher** (phone). The same tabs in the same order, as a grid of cards behind the tab-count button. Each card shows the title (two lines), a miniature of the open page in the book's face (whole lines only, ending in an ellipsis), the format badge, the place and a progress bar; the current tab has an `accent` outline. The library card comes last. **Done** returns to the current book.

**ReaderToolbar.** Title, current place and every reader action.

| Position | Desktop and tablet | Phone |
| --- | --- | --- |
| Leading | Contents (`list`), Search (`search`) | Back to the library (`chevron-left`) |
| Centre | Book title, then the current section in `ink-muted` | Title, then the section |
| Trailing | Display settings (**Aa**), Bookmark (`bookmark`), Notes toggle with count | Search, tab count |

On phones, Contents, Aa, Bookmark and Notes move to the bottom bar that appears with a tap on the page. The same controls appear for EPUB and PDF. The bookmark fills with `vermilion` when the page is bookmarked. The toolbar hides while reading on phone and tablet and returns with a tap.

**StatusBar.** Section title, progress track, then `percent · pages a–b of n` in tabular figures; one page in view reads `page 104 of 502`. The fill is `accent`; bookmarks are `vermilion` ticks. Clicking or dragging the track jumps, and the jump is recorded for Back. On phones it shrinks to the percentage and a page number.

**BackPill.** After any jump (a reference, a contents entry, a search result, a note, the progress track) an `inverse` capsule floats bottom centre and names the origin in the reader's terms: **Back to page 61**, **Back to Chapter III**, never "Back" alone. It stays until you go back, close it, or turn three pages away. Jumps stack; each Back steps one level. Keyboard: Alt+← on Linux and Windows, ⌘[ on macOS.

### Reading

**PageSpread.** The reading surface; see [Reading surfaces](#reading-surfaces). Right-to-left spreads use `sh-spread--rtl`; vertical pages `sh-page--vertical`.

**Highlight.** One selection and highlight model for EPUB and PDF (RFD 6), stored with durable anchors computed in Rust.

- Selecting text raises an `inverse` capsule above the selection (below when there is no room): five colour swatches that save at once, **Note** (saves yellow and opens the editor), **Copy** and **Search**.
- Fills are `hl-*` at 40% with `radius-xs` corners that wrap per line. A highlight with a note gets a dotted underline (`sh-hl--noted`); the one open in the notes panel or just jumped to gets a 2 px `accent` ring (`sh-hl--focus`).
- Tapping a highlight opens the swatches with **Edit note**, **Copy** and **Delete**. Never label colours ("Important").

**ReferencePeek.** Footnotes, cross-references, figure links and contents entries open a peek first.

- Kicker in `ui-label` (`FOOTNOTE 1 · PAGE 2`), a title for sections and figures, then the first lines of the target in `ed-quote`, clamped to five lines with an ellipsis. Figures show the image.
- **Close** and **Go to**. **Go to** records the current place and shows the BackPill.
- Opens under the reference, flipping above when there is no room; a bottom sheet on phones. External web links skip the peek and ask before opening the browser. Esc or a tap outside closes it.

### Notes and search

**NoteCard.** One note or highlight, in the notes panel and in search.

| Kind | Meta line | Body |
| --- | --- | --- |
| Highlight | Colour dot, section and page | The quote in `ed-quote` (four lines at most), then the note if any |
| Page note | `file` icon, **Page note · page 61** | The note |
| Book note | `book` icon, **Book note** | The note |

In **All books** the meta line leads with the format badge and the book title. The card for the highlight in view or just opened takes `aria-current="true"`. Selecting a card jumps to its place; editing happens in place with **Save** and **Cancel**. A highlight without a note shows only its quote.

**NotesPanel.** Every note and highlight for this book or all books, grouped by where they sit.

| Device | Form |
| --- | --- |
| Desktop | Docked right at `panel-width`; the spread narrows, and falls back to one page below `spread-min-width` |
| Tablet | Slides over the page from the right with a `scrim` |
| Phone | A bottom sheet at half height, draggable to full |

Head, then scope and count, then the book note and groups per section in reading order (books, most recently read first, in **All books**), then **Page note** and **Book note** in the foot. Highlights are made from the page, not from here.

**SearchPalette.** Book text and notes together, from any screen. Ctrl+K or ⌘K, `/`, or the Search button opens it, including from the library. Scope is **This book** / **All books** with **Everything** / **Text** / **Notes**. Results are grouped, notes first, then one group per book with its match count (a long title truncates before the count). Each hit has a meta line and a snippet that starts and ends on whole words, with the match marked. Opening a hit jumps there with the match in `search-current` and shows the BackPill. On phones the palette is full screen.

### Settings

**DisplaySettings**, behind **Aa**: the same rows in the same order for both formats.

| Row | EPUB | PDF |
| --- | --- | --- |
| Page theme | Paper, Sepia, Night | Same; Night inverts page luminance |
| Size | **Text size**, 70%–160% in 10% steps; pages reflow and the place is kept | **Zoom**: Fit width, Fit page, then 50%–400%; pages re-render sharp |
| Pages | One or Two; Two by default where the stage is wide enough | Same |
| Font | **Book’s own** (default), Serif, Sans | Not shown: PDF pages keep their fonts |

Theme tiles preview the page colours and take a 2 px `accent` ring when chosen. Changes apply live and are kept per book. Writing direction is not a setting. On phones the popover is a bottom sheet and Pages is hidden in portrait.

### Library

**LibraryBook.** Cover, title, format, place and progress.

- The book's own cover at 2:3, or a typographic cover: title in `ed-quote` weight 600 and author in `ui-label` on one of five fixed grounds chosen by a hash of the title (`brand-navy`, `brand-charcoal`, and the light-theme `vermilion`, `accent` and `success`), with a `brand-gold` band at the top. Generated covers never change with the app theme.
- Title in two lines at most; the meta line is the format badge then `21%`, `Not started` or `Finished`; a 3 px progress bar hides when not started or finished.
- Click opens the book in a new tab, or switches to its tab. The context menu holds **Open in new tab**, **Book note**, **Show file** and **Remove from library**.
- 152 px columns on desktop and two columns on phones. The library screen title is `ui-title`, never the editorial face.

## Iconography

[Lucide](https://lucide.dev), as in the Flutter app (`LucideIcons`): 24 px grid, 1.75 px stroke, round caps and joins, drawn in `currentColor`. 16 px in pointer controls, 20 px in touch controls. Every icon-only button has an `aria-label` and a tooltip with the same words.

| Glyph | Meaning |
| --- | --- |
| `library` | The library tab and Back to library |
| `plus`, `minus` | Open a book, make larger; make smaller |
| `x` | Close a tab, panel or peek |
| `list` | Contents |
| `search` | Search books and notes |
| `bookmark` | Bookmark this page (filled in `vermilion` when set) |
| `message-square-text` | Notes panel; add a note to a highlight |
| `notebook-pen` | Edit a note |
| `file`, `book` | Page note, book note |
| `highlighter` | Highlight, in menus |
| `copy` | Copy text |
| `arrow-right` | Go to a reference |
| `undo-2` | Back to where a jump started |
| `chevron-left`, `chevron-right` | Back to library on phone, previous page; next page |
| `columns-2`, `rectangle-vertical` | Two pages, one page |

Add a glyph only from Lucide, at the same stroke, with a row here and its SVG in `docs/design-system/icons/`.

## Logo

The app icon (`assets/shosai-icon.png`) is the mark: a stack of book spines on cream. In the interface the mark is the character 書 in Noto Serif JP, cream on a `brand-navy` disc (`sh-mark`), beside the wordmark *Shōsai* in `ed-wordmark` (`sh-wordmark`). Always write the name with its macron: Shōsai. Never recolour or redraw the icon.

## Motion

Short and functional: 150 ms for hover and toggles, 200 ms ease-out for popovers, peeks and sheets, page turns 250 ms or instant when the system asks for reduced motion. Nothing loops or bounces.

## Accessibility

- Text meets 4.5:1 on its ground in both themes; control borders, focus rings and icons meet 3:1.
- Focus is a 2 px `accent` ring offset 2 px, on every interactive element.
- Colour is never the only cue: a noted highlight also gets a dotted underline, and every highlight appears in the notes list with its quote and place.
- Everything works by keyboard: Ctrl+K or ⌘K for search, arrow keys and Space for pages, Alt+← or ⌘[ for Back.

## Changing the system

1. Edit `docs/design-system/tokens.json` and run `make design-system-css`; change `components.css` and the affected previews together.
2. Update this document in the same change, and check both app themes in `make design-system`.
3. A change to fonts is also a typography change: follow [typography.md](typography.md).
4. A token the applications need goes into `assets/theme/tokens.json` through its own generator and tests.
