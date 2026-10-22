# Design system

Shōsai (書斎, "the study") is a reader for EPUB and PDF on desktop, tablet and phone. This document is how it looks and speaks: one reading experience whatever the format or the screen. It serves the first release defined in [RFD 4](../rfd/0004/README.adoc) and follows [typography.md](typography.md) for fonts.

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

The previews with Japanese text also load Shippori Mincho from Google Fonts, so the copies in the design system artifact, which does not carry the family's 35 MB of binaries, render the same as the repository's.

### Relationship to the application tokens

The Flutter application renders from `assets/theme/tokens.json` (see [assets/theme/README.md](../assets/theme/README.md)), never by reading `docs/design-system/` at runtime. Since 2026-10-21 that file transcribes this system's colors, radii, spacing and sizes under the same names in camelCase: `ink-muted` is `color.light.inkMuted` and `color.dark.inkMuted` there, and `ShosaiTokens.colorLightInkMuted` in Dart; `space-3` is `space.3`, `sidebar-width` is `size.sidebarWidth`. The application themes' roles (`app.*`, `reader.*`) reference those tokens, so the current screens already paint in D1 paper, and `scripts/tests/test_generate_theme_tokens.py` fails when the two files disagree. The type styles and layered shadows are not transcribed yet; the type sizes and layout metrics the current screens use are still the Iced-era values until the Bookshelf composition replaces them.

### Decisions

Recorded 2026-10-14:

- The accent stays the application's slate (`#4d5e86`). The app icon's vermilion marks only the reader's own bookmarks. The website's green (`#275A47`) is a separate decision.
- `ink-muted` darkens to `#625F57`. The repository's `#726F67` fell to 3.9:1 on the darkest chrome; the new value holds 4.5:1 on every chrome ground.
- Phones in portrait show one page; desktop and tablet in landscape show two by default.

Recorded 2026-10-20, the **Bookshelf** look (D1, paper), chosen over colour-only variants of the first draft and then over a study (walnut and brass) and a desk (flat, vermilion) iteration of the same layout:

- A **sidebar** replaces the tab strip on desktop and tablet: the places (Library, Notes, Bookmarks, Search) and the open books as a **Reading now** list, each keeping its place. While reading it collapses to a 64 px **rail** of icons and the open books' covers. Phones get a **bottom bar** for the places and keep the tab switcher for open books.
- The library is a **shelf**: a Continue reading hero, then the covers in a grid resting on a thin shelf edge under the last row. The hero carries no recent list; the sidebar does.
- Chrome is warm paper in both themes, and the sidebar, rail, toolbar, status line and panels sit on `chrome` (`#ece5d6`), a shade deeper than the library's `canvas` (`#f6f1e6`); no pure grey anywhere. `ink` is a warm black (`#221d18`) and `ink-muted` `#675d4f`, which holds 4.5:1 on every chrome ground.
- Book titles are set in the editorial serif wherever they name a book, and the screen, section and panel titles with them: the library title at 40 px. Controls, labels and meta lines stay in Inter.
- The accent deepens to `#2b3a5c` on light chrome and lifts to `#a8b8df` in dark; the application's `#4d5e86` remains the brand slate for covers and the website.
- The current sidebar entry, note cards, phone tab cards and the library hero are lifted by `shadow-raised` instead of a border; popovers and peeks carry their hairline in their shadow. The reading stage is a radial gradient from `stage` to `stage-edge`.

## Principles

1. **The page is the product.** Chrome is quiet, warm and out of the way. Colour lives on the page (highlights, links) and in one accent; the chrome itself is paper, not plastic.
2. **Format is metadata, not a mode.** EPUB and PDF get the same controls in the same places. A small badge is the only sign of the format.
3. **Layout adapts, behaviour does not.** Panels become sheets, the sidebar becomes a rail and then a bottom bar, and the open books move from the sidebar to a switcher; gestures, words and outcomes stay the same.
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

The app frame in light and dark themes: `canvas` (the library's ground), `chrome` (the sidebar and rail, the reader toolbar and status line, panels and sheets), `surface` (cards, menus, the current sidebar entry), `surface-sunken` (progress tracks, skeletons), `stage` and `stage-edge` (the reading stage, centre and rim), `shelf` (the edge under the library's covers), `hover`, `line`, `line-strong`, `ink` and `ink-muted`.

- Light chrome is warm paper, and the frame is a shade deeper than the room: `canvas` `#f6f1e6`, `chrome` `#ece5d6`, `surface` `#fdfaf3`. Dark chrome is the same paper by lamplight, a warm near-black rather than grey: `canvas` `#1d1915`, `chrome` `#171412`, `surface` `#2a241e`. Neither theme uses a pure grey.
- Text is `ink` (a warm black), or `ink-muted` for secondary text. Both hold 4.5:1 on every chrome ground in both themes.
- `line` is decorative. A control that must be seen (inputs, secondary buttons) uses `line-strong`, which holds 3:1 on every chrome ground except a raised segment, which is lifted by its shadow instead.
- `control-raised` lifts the chosen segment of a segmented control; in dark it is lighter than `surface` so the choice still reads.
- The reading stage is a radial gradient from `stage` at the centre to `stage-edge` at the rim, so the pages sit in light. The shelf edge under the library's covers runs from `line` through `shelf` to `surface-sunken`. These are the only gradients in the system.
- `scrim` dims the page behind slide-over panels and sheets.

### Accent and brand

- `accent` is Shōsai slate, the one interactive colour: primary buttons, selected states (`accent-soft` with `on-accent-soft`), focus rings, progress, the current note. One primary button per surface. On light paper the slate deepens to `#2b3a5c` so it reads as ink rather than paint; in dark it lifts to `#a8b8df`. The application's `#4d5e86` remains the brand slate for generated covers and the website.
- `vermilion` is a seal red. It marks only the reader's own marks: a filled bookmark and bookmark ticks on the progress track. Never a button, never an error.
- `brand-navy` and `brand-cream` are the colours of the app icon and the 書 mark; `brand-mark` picks the one the mark takes on the current theme. `brand-charcoal` and `brand-gold` are for generated covers and marketing. None of them appears in a control.
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

| Role | Family token | Faces (default set) | Use |
| --- | --- | --- | --- |
| Interface | `--font-ui` | Inter, Noto Sans JP | Every control, label, list, meta line and panel body |
| Editorial | `--font-editorial` | Literata, Shippori Mincho | Book titles wherever they name a book (the sidebar's Reading now list, toolbar, library cards, hero, tab cards), screen, section and panel titles, the wordmark, empty-state headlines, generated covers, and quoted book text in notes, peeks and search |
| Book | `--font-book` | The book's own fonts, else Literata and Shippori Mincho | EPUB content only. PDFs keep their embedded fonts |

The faces come from a **type set**, chosen in the Typeface setting (decided 2026-10-21). The default set is Inter + Literata, with Noto Sans JP + Shippori Mincho behind them for Japanese; the five alternatives are Inter + Source Serif 4, IBM Plex Sans + Newsreader, Source Sans 3 + Crimson Pro, Figtree + Fraunces and Manrope + Spectral, each with its own Japanese pair (`type.sets` in `tokens.json`). A set fills all three roles at once: its sans is the interface, its serif the editorial face and the reader's **Serif** choice, its sans the reader's **Sans** choice. The styles below keep their sizes whatever the set. Only the default set is bundled today; the others ship with the setting.

- Interface styles: `ui-title` 20/26, `ui-heading` 16/22, `ui-body` 14/20, `ui-control` 13/18, `ui-caption` 12/16, `ui-label` 11/14 uppercase, `ui-badge` 10/12. Weights 400, 500 and 600 only.
- Editorial styles: `ed-display` 40/44 (the library and other screen titles; 34/38 on tablet, 30/34 on phone), `ed-screen` 34/40 (the Continue reading hero's title), `ed-section` 22/26 (section heads such as *All books*, and panel titles at 20/24), `ed-wordmark` 22/26, `ed-title` 14/19 (book titles in the sidebar, cards and lists; 17/24 in the reader toolbar), `ed-quote` 15/23 (18/27 in the hero). The serif is reserved for what names or quotes a book and for the titles of screens, sections and panels; a serif on a button, a label or a meta line is wrong.
- Book styles: `book-body` 19/31 and `book-body-ja` 20/38 are the defaults when a book sets none; the text-size control scales them from 70% to 160%. `book-chapter` is the fallback chapter label; `book-folio` sets running heads and folios at 60% of the page ink.
- Never synthesize bold or italic. Set figures in places and counts with `font-variant-numeric: tabular-nums`.
- `ui-label` is for Latin text. Japanese labels use `ui-caption` without letter spacing.

## Space, size and layout

Spacing runs on a 4 px base: `space-1` 4, `space-2` 8, `space-3` 12, `space-4` 16, `space-5` 24, `space-6` 32, `space-7` 48. Card padding is `space-3`; sheet padding and phone gutters `space-4`; the reading stage `space-5`.

| Token | Value | Use |
| --- | --- | --- |
| `control-height` | 32 px | Buttons and fields with a pointer |
| `touch-target` | 44 px | Every control on tablet and phone |
| `sidebar-width` | 240 px | The library sidebar on desktop; 220 px on tablet |
| `rail-width` | 64 px | The rail the sidebar collapses to while reading; 56 px on tablet |
| `bottomnav-height` | 64 px | The phone's bottom bar |
| `toolbar-height` | 56 px | Reader toolbar, on every layout |
| `statusbar-height` | 36 px | Status line under the page |
| `panel-width` | 340 px | Docked notes panel; 360 px as a slide-over on tablet |
| `spread-min-width` | 720 px | Narrowest stage that shows two pages |
| `measure` | 36em | Widest EPUB text column |

Layouts by width: **phone** below 600 px (one page, sheets, bottom bar, tab switcher), **tablet** 600–1199 px (sidebar and rail, slide-over panels, two pages in landscape), **desktop** 1200 px and up (sidebar and rail, docked panels, two pages).

Radii: `radius-xs` 2 (highlights), 3 px for pages and covers, `radius-sm` 6 (buttons), 8 px for sidebar rows and the search field, `radius-md` 10 (cards, popovers, peeks), 12 px for dialogs and phone Reading now cards, 16 px for the library hero, `radius-lg` 16 (sheet tops). Capsules are fully round.

Elevation is five layered shadows per theme, each a tight contact shadow under a soft ambient one: `shadow-raised` for the current sidebar entry, note cards, phone tab cards and the library hero (a card lifted a millimetre off the paper), `shadow-page` for pages on the stage, `shadow-cover` for library covers, `shadow-menu` for capsules, `shadow-modal` for search, popovers, peeks, dialogs and sheets. Cards that carry `shadow-raised` have no border, and popovers and peeks carry their hairline inside `shadow-modal`; borders separate everything else.

## Reading surfaces

The page is set like print, on a stage lit from the centre.

- **Two pages by default** on desktop and tablet in landscape whenever the stage is at least `spread-min-width` wide; **one page** on phones and in portrait. The reader can choose one or two in Display settings, for EPUB and PDF alike.
- **No clipped lines.** Text flows from page to page and breaks at real line starts, so a page holds whole lines only and leftover space at the foot is less than one line. A paragraph that crosses a page continues without an indent, and its last line on the earlier page is justified.
- **Justified text is hyphenated**, so narrow phone pages do not open wide gaps between words. A hyphenated word never splits across a page turn.
- **Chapter openings** drop the running head and sink the title. Other pages carry a running head and a centred folio in `book-folio`.
- **EPUB page numbers** are Shōsai's own pagination at the current size and margins; the same numbers appear in the status line, notes and search results.
- **The book's direction.** Right-to-left books turn leftward with the first page on the right; vertical Japanese keeps `vertical-rl`. Undeclared books read horizontally. There is no override.
- **PDF stays the PDF.** Pages re-render at the current zoom so text is sharp on any screen; on phones they fit the width. Night inverts page luminance.

Layout, pagination and durable anchors come from the Dart document engines and application core; Flutter renders the laid-out pages (see [flutter-architecture.md](flutter-architecture.md)).

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

**FormatBadge.** The format in capitals (`EPUB`, `PDF`) in `ui-badge` on `surface-sunken`, beside a title in the sidebar's Reading now list, library rows, search results and note cards. It never sits next to a control, is never colour-coded, and is left out where one book is in view and the title already identifies it.

### Navigation

**Sidebar** (desktop and tablet). The study's left wall: the places you can go and the books you have open. It replaces the tab strip.

1. The 書 mark and the wordmark, then a field-shaped **Search** button with its shortcut (desktop only).
2. The places **Library**, **Notes**, **Bookmarks** and **Search** as 34 px rows with 8 px corners. The current place is a `surface` card lifted by `shadow-raised`, its icon in `accent`; the others sit flat on `chrome` in `ink` and take `hover` under the pointer. Notes and Bookmarks open the library-side lists across all books.
3. **Reading now**: every open book in the order opened, a 34 px cover, the title in `ed-title` at 13/17, the place in `ui-caption` and a 3 px progress bar. The current book is lifted like the current place. The close button shows on hover and always on touch; closing the current book selects the one below it, else above, and with none left the library shows. Rows reorder by dragging and survive relaunch, as tabs did.
4. **Add books** at the foot opens the file picker.

While reading the sidebar collapses to the **rail** (`sh-sidebar--rail`, `rail-width`): the mark, the four places as icon buttons with tooltips, then the open books as 30 px covers under a hairline, the current one outlined in `accent`. The rail never hides; the reader toolbar sits beside it. Width is `sidebar-width`; the sidebar does not resize.

**BottomNav** (phone). The sidebar's four places as icons over 10 px labels in a `bottomnav-height` bar on `chrome`; the current place is `accent`. It shows on the library-side screens only; the reader keeps its own bottom bar and reaches the library through the toolbar's back chevron. On the phone's library the open books appear as **Reading now** cards above the grid instead of a hero.

**TabSwitcher** (phone). The open books, in the sidebar's order, as a grid of cards behind the tab-count button in the reader toolbar. Each card shows the title (`ed-title`, two lines), a miniature of the open page in the book's face (whole lines only, ending in an ellipsis), the format badge, the place and a progress bar; cards are `surface` lifted by `shadow-raised`, and the current one is outlined in `accent`. The library card comes last. **Done** returns to the current book.

**ReaderToolbar.** Title, current place and every reader action.

| Position | Desktop and tablet | Phone |
| --- | --- | --- |
| Leading | Contents (`list`) | Back to the library (`chevron-left`) |
| Centre | Book title in the editorial serif (17/24), then the current section in `ui-caption` `ink-muted` | Title, then the section |
| Trailing | Display settings (**Aa**), Bookmark (`bookmark`), Notes toggle with count | Search, open-book count |

On phones, Contents, Aa, Bookmark and Notes move to the bottom bar that appears with a tap on the page. Search lives in the rail on desktop and tablet, so the toolbar leads with Contents alone. The same controls appear for EPUB and PDF. The bookmark fills with `vermilion` when the page is bookmarked. The toolbar sits on `chrome`, is `toolbar-height` tall on every layout, and hides while reading on phone and tablet, returning with a tap.

**StatusBar.** Section title, progress track, then `percent · pages a–b of n` in tabular figures; one page in view reads `page 104 of 502`. The fill is `accent`; bookmarks are `vermilion` ticks. Clicking or dragging the track jumps, and the jump is recorded for Back. On phones it shrinks to the percentage and a page number.

**BackPill.** After any jump (a reference, a contents entry, a search result, a note, the progress track) an `inverse` capsule floats bottom centre and names the origin in the reader's terms: **Back to page 61**, **Back to Chapter III**, never "Back" alone. It stays until you go back, close it, or turn three pages away. Jumps stack; each Back steps one level. Keyboard: Alt+← on Linux and Windows, ⌘[ on macOS.

### Reading

**PageSpread.** The reading surface; see [Reading surfaces](#reading-surfaces). Right-to-left spreads use `sh-spread--rtl`; vertical pages `sh-page--vertical`.

**Highlight.** One selection and highlight model for EPUB and PDF (RFD 6), stored with durable anchors computed in the Dart application core.

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

In **All books** the meta line leads with the format badge and the book title. Cards are `surface` lifted by `shadow-raised`, with no border; under the pointer they take a `line-strong` ring, and the card for the highlight in view or just opened takes `aria-current="true"`, a 2 px `accent` ring. Selecting a card jumps to its place; editing happens in place with **Save** and **Cancel**. A highlight without a note shows only its quote.

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
| Typeface | The current type set’s name, opening the TypefacePicker | Same |

Theme tiles preview the page colours and take a 2 px `accent` ring when chosen. Changes apply live and are kept per book, except Typeface, which is one choice for the whole application. Writing direction is not a setting. On phones the popover is a bottom sheet and Pages is hidden in portrait.

**TypefacePicker.** The six type sets as a radio list (`role="radiogroup"`), each row showing the set’s name in its sans, its faces in `ui-caption` and a one-line specimen in its serif, so the choice is made by looking rather than by name. The current set carries a check in `accent`. Choosing applies at once to the interface, the editorial text and the reader’s Serif and Sans fonts; a book’s own fonts are untouched. Rows never preview with system fallbacks: a set that is not bundled is not listed.

### Library

**ContinueReading.** The library opens on the book you were in: a `surface` hero with 16 px corners, lifted by `shadow-raised` and a soft ambient shadow, the one lifted card on the library canvas.

- Cover at 168 px under a deep cover shadow, the kicker *Continue reading* in `ui-label`, the title in `ed-screen`, author and format badge, then the book's latest highlight or note quoted in the editorial face at 18/27 (hidden when there is none, never a placeholder), the place in the reader's terms over a 4 px progress bar at most 480 px wide, and **Continue** (primary) beside **Notes** with its count.
- It shows the book last opened for reading, not the last added, and carries no recent list: the other open books are in the sidebar's Reading now. The compact form (`sh-hero--compact`) for narrow tablets drops the quote and puts the cover at 72 px; phones replace the hero with Reading now cards.
- The library screen is titled *Library* in `ed-display` with the book and open counts beside it and the sort control at the right; the shelf below sits under an **All books** section head (`ed-section`) that runs a `line` rule to the right edge.

**LibraryBook.** Cover, title, format, place and progress, on the shelf.

- The book's own cover at 2:3, or a typographic cover: title in `ed-quote` weight 600 and author in `ui-label` on one of five fixed grounds chosen by a hash of the title (`brand-navy`, `brand-charcoal`, and the light-theme `vermilion`, `accent` and `success`), with a `brand-gold` band at the top. Generated covers never change with the app theme, carry a faint sheen (`sh-cover::after`) and stand off the paper under `shadow-cover`.
- Title in `ed-title`, two lines at most; the meta line is the format badge then `21%`, `Not started` or `Finished`; a 3 px progress bar hides when not started or finished.
- Click opens the book, or switches to it if it is already open. The context menu holds **Open**, **Book note**, **Show file** and **Remove from library**.
- The shelf (`sh-shelf`) fills with columns of at least 118 px at a 28 px gap (seven across at 1440 px, six on a tablet) and three columns on phones. A thin shelf edge (`sh-shelf__edge`) runs under the bottom row on desktop and tablet, bleeding to the screen's edges, so the covers rest on something.

## Iconography

[Lucide](https://lucide.dev), as in the Flutter app (`LucideIcons`): 24 px grid, 1.75 px stroke, round caps and joins, drawn in `currentColor`. 16 px in pointer controls, 20 px in touch controls. Every icon-only button has an `aria-label` and a tooltip with the same words.

| Glyph | Meaning |
| --- | --- |
| `library` | The Library place in the sidebar, rail and bottom bar |
| `plus`, `minus` | Add books, make larger; make smaller |
| `x` | Close an open book, panel or peek |
| `list` | Contents |
| `search` | Search books and notes |
| `bookmark` | Bookmarks in the sidebar; bookmark this page (filled in `vermilion` when set) |
| `message-square-text` | Notes: the place in the sidebar, the reader's panel, a note on a highlight |
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

The mark is 丸に書 (decided 2026-10-21): the character 書, set in Noto Serif JP Black, inside a plain ring, in the manner of a family crest. It is one colour on any ground: `brand-navy` on light grounds, `brand-cream` on dark, which `brand-mark` selects in the interface. The files live in `assets/logo/`:

| File | What it is |
| --- | --- |
| `shosai-mark.svg` | The mark alone, outlined, in `currentColor` on a 100-unit box: ring radius 45 at a stroke of 5.5, the character 54 units tall. Use this everywhere the mark is drawn, at any size. |
| `shosai-icon.svg`, `assets/shosai-icon.png` | The app icon: the mark in `brand-navy` on a full-bleed `brand-cream` square, at 72% of the side. Platforms mask it themselves (iOS, Android). |
| `shosai-icon-macos.svg` | The macOS icon: the same on a rounded square with the system corner radius and transparent margins. |
| `website/static/favicon.svg` | The favicon: the mark on a cream rounded square. |

In the interface the mark is `sh-mark`: 30 px, the ring a 2 px border in `brand-mark`, the character in Noto Serif JP at weight 900, beside the wordmark *Shōsai* in `ed-wordmark` (`sh-wordmark`) at the head of the sidebar; the rail keeps the mark alone. Keep clear space of at least a quarter of the mark’s width on every side, and do not set the mark smaller than 16 px. Always write the name with its macron: Shōsai. Never recolour, outline, shade or redraw the mark; the ring and the character always move together.

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
4. Copy every token change into `assets/theme/tokens.json` under the same camelCase name and run `make theme-tokens`; the generator's tests compare the two files.
