# Design tokens

`assets/theme/tokens.json` is the single tracked design-token source for the
Flutter frontend (restoration plan decision 2: "One tracked token source
supplies both frontends, including application and reader palettes, type scale,
radii and gate-relevant layout metrics"). Nothing else may define a theme
color.

Since 2026-10-21 its colors, radii, spacing and sizes are the Shōsai design
system (`docs/design-system.md`, tokens in `docs/design-system/tokens.json`):
the Bookshelf look, D1 paper, the 丸に書 mark colors and the Inter + Literata
type set. The type sizes and layout metrics are still the values transcribed
from the pinned Iced reference, until the Bookshelf composition replaces the
screens that read them. The Iced application itself (`crates/shosai-app`) was
removed on 2026-10-20 (RFD 12, "The first release").

| File | Role |
| --- | --- |
| `assets/theme/tokens.json` | The source. Edit this file only. |
| `lib/theme_tokens.dart` | Generated Dart token class, consumed by `lib/app_theme.dart` and the reader paint path. |
| `scripts/generate-theme-tokens.py` | Generates the Dart module and checks it (`--check`). |

```sh
make theme-tokens          # regenerate the Dart module after editing the JSON
make check-theme-tokens    # verify the committed module still matches the source
```

The generator's `--check` gate runs in `make test-scripts` through
`scripts/tests/test_generate_theme_tokens.py`, which also checks that every
design-system color, radius, spacing and size token is transcribed here with
the same value. The Dart side cross-checks the JSON in
`test/app_theme_test.dart`.

## Sections

| Section | Contents | Dart names |
| --- | --- | --- |
| `color.light.*`, `color.dark.*` | The design system's themed colors, name for name in camelCase (`ink-muted` → `inkMuted`). | `colorLightInkMuted`, `colorDarkChrome`, … |
| `color.*` | The unthemed colors: `brand*`, `page*`, `hl*`, `swatch*`, `selection`, `searchHit`, `searchCurrent`. | `colorBrandNavy`, `colorPagePaper`, … |
| `app.*`, `app.dark.*` | The roles the Shad and Material themes read, as references into `color.light` and `color.dark`. | `appBackground`, `appDarkPrimary`, … |
| `reader.<light,dark,sepia>.*` | The document palettes, referencing the page themes (paper, night, sepia). | `readerSepiaText`, … |
| `radius.*` | `xs`, `sm`, `md`, `lg` from the design system; `small`, `medium`, `progress` are the names the themes already read. | `radiusMd`, `radiusSmall`, … |
| `space.*`, `size.*` | The design system's spacing scale and fixed sizes, in logical pixels (`size.measure` is in em). | `space3`, `sizeSidebarWidth`, … |
| `type.family.*`, `type.size.*` | Interface and editorial families (the default type set); the Iced-era size scale. | `typeFamilyEditorialLatinFlutter`, `typeSize14`, … |
| `layout.*` | Iced-era composition metrics. | `layoutLibraryCardHeight`, … |

A value written `{path}` references another token, as the design system writes
`{surface}`. The generator resolves it for validation and emits the Dart
constant as a reference to the other constant (`appBackground =
colorLightCanvas`), so a role can never drift from the token it names.

The design system's layered shadows (`shadow-page`, `shadow-cover`, …) are CSS
box-shadow lists and are not transcribed; `app.shadow.*` keeps the Iced-era
single-layer weights over the design system's shadow ink. The type styles
(`ui-*`, `ed-*`, `book-*`) are not transcribed yet either.

## Authority

Each token group records its authority in the JSON `meta.authority` map, and the
generated module repeats it as a doc comment on every constant. `Iced` names
the removed application at the pinned reference revision: the historical source
of the value, not a live consumer.

| Group | Authority |
| --- | --- |
| `color.*`, `space.*`, `size.*` | `Design system` — `docs/design-system/tokens.json`. |
| `app.*`, `app.dark.*` | `Design system` light and dark themes, through references into `color.*`. `app.dark` maps the Shad roles: background = canvas, card, popover and secondary = surface, primary and ring = accent, muted = surface-sunken, accent and selection = accent-soft, border = line, input = line-strong, destructiveForeground = canvas. |
| `reader.*` | `Design system` page themes, except the table-header colors and `reader.codeBlock.fallbackBackground`, which have no design-system token and keep the Iced values. |
| `radius.*` | `Design system`. |
| `type.family.*` | `Design system` type set `inter-literata`. The `iced` keys on the interface and math families record the removed application's names. |
| `type.size.*`, `type.reader.*`, `type.bookmark.*`, `layout.*` | `Iced` — specification §3.4 and §3.5. |
| `layout.library.card.*` | `Iced` — the pinned card composition (`crates/shosai-app/src/app.rs` `render_book_card`, `crates/shosai-app/src/widgets.rs` `book_button`). |

Per-key exceptions to a group are recorded under their own `meta.authority` key.
The card trigger's two scrim weights (`layout.library.card.triggerScrimAlpha`,
`layout.library.card.triggerScrimActiveAlpha`) are `Retained Flutter`: the owner
asked for a subtler trigger than the pinned Iced `book_card_action` surface
(2026-09-25), so the reference's painted geometry — its 13 px glyph, `[5, 8]`
padding and `radiusSmall` — is filled with a translucent ink scrim instead of the
opaque `SURFACE` square with its `BORDER`. `layout.library.card.placeholderPadding`
is the same kind of exception.

Plan decision 2 also rejects the historical #109 brown accent. `app.accent` must
stay the design system's slate `#2B3A5C` (it replaced the Iced `#4D5E86` with D1
paper on 2026-10-20) and no token value may be `#8A6338`; the generator and both
sides' tests enforce that.

## Flutter mapping

`lib/app_theme.dart` builds every theme from the tokens:

| Flutter theme | Tokens |
| --- | --- |
| `shosaiShadTheme(Brightness.light)` | `app.*`; inputs `color.light.lineStrong`, quiet selected text `color.light.onAccentSoft` |
| `shosaiShadTheme(Brightness.dark)` | `app.dark.*` |
| `shosaiReaderShadTheme(<any reader theme>)` | `app.*` (owner decision 2026-09-28: the chrome does not follow the reader theme) |
| reader page colors (`pageColors`) | `reader.<theme>.*` |
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

## Rust mapping (historical)

Until 2026-10-20 the generator also wrote `crates/shosai-app/src/theme_tokens.rs`,
which the Iced application's `theme`, `typography`, `app` and `widgets` modules
read. That module went with the crate. `crates/shosai-core` never read the
tokens: `math_layout::MATH_FONT_FAMILY` keeps its own literal, which the
removed app-side test used to compare against `type.family.math.iced`.

## Rejecting new literal theme colors

* `test/app_theme_test.dart` scans `lib` for `Color(0x…)`,
  `Color.from…`, `Color.fromARGB` and `Colors.*` and fails outside the generated
  `theme_tokens.dart`.

## Open items

* The golden baselines under `test/goldens/` (Linux reference) and
  `test/goldens/macos/` render these tokens; a color change here is
  re-rendered on both platforms in the same change.
* The design system's type styles and layered shadows are not in this file
  yet; they arrive with the Bookshelf composition that reads them.
