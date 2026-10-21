# Typography

Shōsai uses a small, deliberate type system shared by the desktop application and website. Do not select fonts ad hoc or rely on whichever system fallback happens to be installed.

## Families and roles

| Role | Latin | Japanese | Use |
| --- | --- | --- | --- |
| Interface sans | Inter | Noto Sans JP | Application chrome, controls, settings, navigation, labels, metadata, and website body copy |
| Editorial serif | Literata | Shippori Mincho | Brand wordmark, marketing headings, book titles wherever the application names a book, screen and panel titles, quoted book text, and other intentionally editorial surfaces |
| Book content | Document font or reader preference | Document font or reader preference | EPUB content only; PDF pages retain their embedded appearance |

The interface and editorial roles are distinct. Do not use the serif pair for ordinary controls, labels or meta lines, and do not force application fonts onto book content. [design-system.md](design-system.md) lists the editorial text styles and where each is used.

The 書 of the brand mark is the one glyph set outside these roles: Noto Serif JP at weight 900, from a subset that holds only U+66F8.

## Type sets

The faces above are the default **type set**, Inter + Literata (decided 2026-10-21). The application offers five more sets in its Typeface setting; a set fills the interface role with its sans, the editorial role with its serif, and the reader's Serif and Sans font choices with the same two faces.

| Set | Latin sans | Latin serif | Japanese sans | Japanese serif |
| --- | --- | --- | --- | --- |
| Inter + Literata (default) | Inter | Literata | Noto Sans JP | Shippori Mincho |
| Inter + Source Serif 4 | Inter | Source Serif 4 | Noto Sans JP | Noto Serif JP |
| IBM Plex Sans + Newsreader | IBM Plex Sans | Newsreader | IBM Plex Sans JP | Zen Old Mincho |
| Source Sans 3 + Crimson Pro | Source Sans 3 | Crimson Pro | Noto Sans JP | Noto Serif JP |
| Figtree + Fraunces | Figtree | Fraunces | M PLUS 1p | Zen Old Mincho |
| Manrope + Spectral | Manrope | Spectral | Noto Sans JP | Shippori Mincho |

Only the default set is bundled (`assets/fonts/`). The other sets are added through the steps below when the Typeface setting ships; a set is offered only once every face in it is bundled. The website uses the default set and does not offer a choice. `docs/design-system/tokens.json` (`type.sets`) is the list the application reads.

## Application rules

- Bundle every font required by a supported interface language. Supported UI must not depend on system font discovery or fallback.
- Use the current set's sans (Inter by default) for English UI and its Japanese sans (Noto Sans JP by default) for Japanese UI. Mixed-script and user-provided metadata must select a bundled face that covers the displayed text.
- Use the named typography constants rather than `Font::DEFAULT` or literal family names.
- Use real available weights. The normal UI range is 400–700; do not synthesize bold or italic faces.
- A language change must update immediately. Treat a transition above 100 ms on a release build as a performance regression.
- Reader typography is a separate concern. EPUB embedded fonts and reader font preferences take precedence over UI fonts.

## Website rules

- Self-host the same families; do not depend on visitors having them installed.
- Use `--font-ui` and `--font-editorial` rather than literal stacks in individual selectors.
- Keep font files under `assets/fonts` as the source of truth and expose them to Hugo through its static mount.
- Subsetting is allowed for a static, known character set, but the subset, source, generation method, and covered characters must be documented. Regenerate it when relevant content changes.
- Preserve `font-display: swap` and avoid loading Japanese fonts on pages that do not render Japanese glyphs.

## Adding or upgrading a font

1. Confirm that its license permits application embedding and web self-hosting.
2. Add the upstream license and record the source revision or release, URL, and SHA-256 checksum in `assets/fonts/README.md`.
3. Prefer upstream variable TTF files for the native app. Use WOFF2 or a documented subset for web delivery when the full font would materially increase page weight.
4. Verify family names and required glyph coverage from the actual binary.
5. Review English, Japanese, and mixed-script text at normal, compact, and high-DPI layouts.
6. Run the application tests, website build, and a language-switch latency check.

Font changes are design-system changes. They require review of both products even when only one currently uses the affected role.
