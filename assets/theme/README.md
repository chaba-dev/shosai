# Design tokens

`assets/theme/tokens.json` is the single tracked design-token source for the
desktop application and the Flutter frontend (restoration plan decision 2: "One
tracked token source supplies both frontends, including application and reader
palettes, type scale, radii and gate-relevant layout metrics"). The Iced
frontend supplies the values; the file transcribes them from the pinned
reference and nothing else may define a theme color.

| File | Role |
| --- | --- |
| `assets/theme/tokens.json` | The source. Edit this file only. |
| `crates/shosai-app/src/theme_tokens.rs` | Generated Rust token table, consumed by `crate::theme` (colors), `crate::typography` (families) and `crate::app` / `crate::widgets` (the reader, library, cover and button metrics this package migrates). |
| `flutter/lib/theme_tokens.dart` | Generated Dart token class, consumed by `flutter/lib/app_theme.dart` and the reader paint path. |
| `scripts/generate-theme-tokens.py` | Generates both files and checks them (`--check`). |

```sh
make theme-tokens          # regenerate both files after editing the JSON
make check-theme-tokens    # verify the committed files still match the source
```

The generator's `--check` gate runs in `make test-scripts` through
`scripts/tests/test_generate_theme_tokens.py`, and the Dart side cross-checks the
JSON in `flutter/test/app_theme_test.dart`.

## Authority

Each token group records its authority in the JSON `meta.authority` map, and the
generated files repeat it as a doc comment on every constant.

| Group | Authority |
| --- | --- |
| `app.*` | `Iced` — `crates/shosai-app/src/theme.rs` at the pinned reference. |
| `app.dark.*` | `Retained Flutter` — Iced defines no dark application palette. The values are the shadcn_ui 0.56.3 `stone` dark scheme this application already rendered with, frozen here so the dark theme is mapped from tokens instead of a package default. |
| `reader.<light,dark,sepia>.*` | `Iced` — the reader document palettes (specification §3.3). |
| `reader.selection.*`, `reader.annotation.*` | `Retained Flutter` — RFD 6 selection/highlighting has no Iced reference (plan decision 8); these are the colors the application already painted with. |
| `radius.*`, `type.*`, `layout.*` | `Iced` — specification §3.4 and §3.5. |
| `layout.library.card.*` | `Iced` — the pinned card composition (`crates/shosai-app/src/app.rs` `render_book_card`, `crates/shosai-app/src/widgets.rs` `book_button`). The specification's §3.5 table names the grid metrics and its prose names the collection padding; the card's internal metrics are recorded in the source so the Flutter card and the Iced card cannot drift. The pinned Iced card still writes these values literally; the Rust migration is not part of package 3B. |

Per-key exceptions to a group are recorded under their own `meta.authority` key.
The card trigger's two scrim weights (`layout.library.card.triggerScrimAlpha`,
`layout.library.card.triggerScrimActiveAlpha`) are `Retained Flutter`: the owner
asked for a subtler trigger than the pinned Iced `book_card_action` surface
(2026-09-25), so the reference's painted geometry — its 13 px glyph, `[5, 8]`
padding and `radiusSmall` — is filled with a translucent ink scrim instead of the
opaque `SURFACE` square with its `BORDER`. `layout.library.card.placeholderPadding`
is the same kind of exception.

Plan decision 2 also rejects the historical #109 brown accent. `app.accent` must
stay `#4D5E86` and no token value may be `#8A6338`; the generator and both sides'
tests enforce that.

## Flutter mapping

`flutter/lib/app_theme.dart` builds every theme from the tokens:

| Flutter theme | Tokens |
| --- | --- |
| `shosaiShadTheme(Brightness.light)` | `app.*` |
| `shosaiShadTheme(Brightness.dark)` | `app.dark.*` |
| `shosaiReaderShadTheme('light')` | `app.*` (the pinned Iced reader chrome) |
| `shosaiReaderShadTheme('dark')` | `app.dark.*` |
| `shosaiReaderShadTheme('sepia')` | `reader.sepia.*` surfaces and text with the `app.*` structural roles and accent |
| `shosaiReaderMaterialTheme` page colors | `reader.<theme>.*` (what `pageColors` reads) |
| Material text roles | `type.size.*`, mapped role by role to the Iced UI scale |
| Shad text roles | `type.size.*`; a role without an Iced counterpart keeps its Shad default |
| radii | `radius.small` (Shad theme radius) and `radius.medium` |

Interface fonts (`type.family.ui.*`) are used for chrome and metadata only.
EPUB book text keeps the document font or the reader preference; the Flutter
themes never override it, and `shosaiInterfaceFontForText` keeps the bundled
Inter face as the fallback when Noto Sans JP is the primary face.

The Flutter themes consume the color, radius and type tokens. The `layout.*`
metrics are in the source for the composition packages that consume them
(3A-3D, 4B-4C, 6A-6B); 3A consumes the library navigation metrics, 3B the
grid and card metrics (`layout.library.grid*`, `layout.library.card.*`,
`layout.library.collectionPadding*`) and 3C the collection's remaining metrics
(`layout.continueCard.*`, `layout.library.skeleton.*`,
`layout.library.emptyState.*`, `layout.library.sectionSpacing`,
`layout.library.alertPadding*`,
`layout.library.continueSectionTrailingSpace`).

## Rust mapping

`crate::theme` converts the generated tuples into `iced::Color` with four
`const fn` helpers and keeps the public names (`APP_BACKGROUND`, `ACCENT`,
`RADIUS_SMALL`, …). The Iced style functions, the reader palettes, the
application palette and the reader code-block fallback all read those
constants. `crate::typography` takes the interface family names from the tokens,
and `crate::app` / `crate::widgets` take the reader chrome, spread threshold,
library breakpoint, page size, cover decode bounds and button geometry they
already used from `layout.*`. The remaining `layout.*` values (import review
rows, modal widths, settings content width, the collection's section, alert,
continue-card, skeleton and empty-state metrics) are catalogued for the packages
that own those surfaces and are not migrated here.

`crates/shosai-core` cannot depend on the application crate, so
`math_layout::MATH_FONT_FAMILY` keeps its own literal; the app-side token test
asserts that literal equals `type.family.math.iced`, which keeps the two sides
from drifting without adding a second generated table to the core crate.

## Rejecting new literal theme colors

* `crates/shosai-app/src/theme.rs` has a test that scans every application
  module for literal color constructors and fails on any file outside a
  one-entry allowlist (the EPUB document text fallback in
  `epub/native_text.rs`, which is not an interface color). Test modules are not
  scanned.
* `flutter/test/app_theme_test.dart` scans `flutter/lib` for `Color(0x…)`,
  `Color.from…`, `Color.fromARGB` and `Colors.*` and fails outside the generated
  `theme_tokens.dart`.

## Open items

* The macOS goldens under `flutter/test/goldens/macos/` are unaffected by this
  file until a macOS run produces and reviews its own candidates; the Linux
  candidates in `rfd/0004/evidence/theme-mappings-2c/candidates/linux/` are
  pending owner approval.
* `app.dark.*` is a retained-Flutter palette. If the owner later decides the
  dark application chrome should follow the Iced dark reader palette, that is a
  new design decision and a token change, not an implementation detail.
