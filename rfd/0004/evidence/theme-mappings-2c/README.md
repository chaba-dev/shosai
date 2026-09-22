# Theme mapping evidence (package 2C)

Evidence for package 2C, "shared tokens, Rust theme mapping, `app_theme.dart`,
paint palettes" ([restoration plan](../flutter-ui-restoration-plan.md) stage 2,
[reference specification](../../../docs/flutter-ui-reference-spec.md) rows
`XA-04`, `XA-05`, `XA-11`, `LB-23`).

- Base revision: `2473383965179e05c4155d228e41fc94e923da55` (#121).
- Pinned Iced reference: `1e54270a6bb24f15630ece336a0575bdbe5be113` (#108).
- Recorded: 2026-09-22, runner `framework16`, Linux (FreeType) rendering.
- Machine-readable record: [`manifest.json`](manifest.json).

## What is in this directory

| Path | Contents |
| --- | --- |
| `palette/` | The `2C-PALETTE` renders: the library under the application light and retained dark palettes, and the reader under the light, dark and sepia document palettes. Each render asserts the palette the tree actually used before it is captured. |
| `candidates/linux/` | Candidate Linux goldens for the 13 baselines the mapping changes, **pending owner approval**. The approved baselines in `flutter/test/goldens/` are unchanged. |
| `manifest.json` | Token-source, generated-file, render and candidate hashes, the before/after diff of every candidate, and the test commands and results. |

## What changed and why it changes pixels

The mapping replaces the Flutter/Shad defaults the frontend rendered with the
pinned Iced values, so every baseline that shows an application or reader
surface changes. The intended difference is the same in every candidate: the
dominant surface moves from a package default (`#FFFFFF` in the library,
`#FFF8F5` in the reader, both derived from the Shad `stone` scheme) to the mapped
token (`#F4F2ED` application background, `#FFFEFB` surface, `#FFFFFF` reader
light background), and accent-colored elements move to `#4D5E86`.

| Candidate | Approved → candidate dominant | Diff |
| --- | --- | --- |
| `library-normal-1280` | `#FFFFFF` → `#F4F2ED` | 97.38% of pixels, max channel delta 232 |
| `library-compact-390` | `#FFFFFF` → `#FFFEFB` | 95.58% |
| `library-compact-390-ja-t200` | `#FFFFFF` → `#FFFEFB` | 97.05% |
| `library-wide-900-ja-t200` | `#FFFFFF` → `#FFFEFB` | 96.37% |
| `library-mixed-1280` | `#FFFFFF` → `#F4F2ED` | 98.69% |
| `library-empty-1280` | `#FFFFFF` → `#F4F2ED` | 100.00% |
| `library-expanded` | `#FFFFFF` → `#F4F2ED` | 100.00% |
| `library-cleanup-pending` | `#FFFFFF` → `#F4F2ED` | 100.00% |
| `library-managed-deletion-pending` | `#FFFFFF` → `#F4F2ED` | 100.00% |
| `library-compact-large-text` | `#FFFFFF` → `#F4F2ED` | 100.00% |
| `reader-welcome-1280` | `#FFF8F5` → `#FFFFFF` | 100.00% |
| `reader-epub-1280` | `#FFF8F5` → `#FFFFFF`, page ink `#221A14` → `#1A1A1A` | 100.00% |
| `reader-pdf-1280` | `#FFF8F5` → `#FFFFFF`, accents `#88511D` → `#4D5E86` | 51.85% |

`reader-epub-1280` also shows the reader's EPUB raster recolored with the mapped
document text color (`reader.light.text`), and `reader-pdf-1280` keeps its
raster colors (PDF pages are never recolored).

The harness's structural diagnostic flags four renders as changed
(`library-compact-390`, `library-compact-390-ja-t200`, `library-wide-900-ja-t200`,
`reader-pdf-1280`) because the ink mask is measured against each frame's own
background, which is what moved. The renders contain zero clipping or overflow
findings, and the geometry of every element is unchanged.

## Candidate verification

| Step | Command | Result |
| --- | --- | --- |
| Approved baselines | `flutter test` | 381 passed, 13 failed — all 13 are the golden pixel comparisons listed above |
| Candidates installed | `flutter test --update-goldens test/product_shell_test.dart test/visual/production_shell_golden_test.dart test/visual/render_structure_test.dart` | 66 passed |
| Candidates re-checked | the same three files without `--update-goldens` | 66 passed |

The failing-before-candidate run is preserved separately in
`manifest.json.test_results.flutter_full_against_approved_baselines`. The
approved goldens were restored after the candidate run and re-hashed to confirm
they are byte-identical to the base revision.

## Palette inspection

The five renders in `palette/` were inspected with `view_media` on 2026-09-22:

- Library light: warm `#F4F2ED` background, `#FFFEFB` cards, `#4D5E86` primary
  action and selected-filter treatment.
- Library dark: the retained dark palette (`#0C0A09` background, `#FAFAF9`
  primary), since Iced defines no dark application palette.
- Reader light: `#FFFFFF` document surface, `rgb(0.1)` document ink, application
  chrome with the `#4D5E86` accent.
- Reader dark: `rgb(0.12,0.12,0.14)` surface, `rgb(0.85)` ink, dark link
  `#8AB4F8` on the focus ring.
- Reader sepia: `rgb(0.96,0.92,0.84)` surface, `rgb(0.3,0.2,0.1)` ink, sepia
  link `#683D00` on the focus ring, and the Iced accent — not the rejected
  historical brown — on the primary action.

## Limits

- The macOS baselines under `flutter/test/goldens/macos/` are unchanged and
  cannot be produced on Linux; a macOS run has to render and review its own
  candidates before that platform is resolved.
- These are Linux FreeType renders. macOS rasterisation differs and is reviewed
  per platform, per the 2B golden policy.
- The native macOS picker smoke from 2B remains open; this package makes no
  macOS validation claim.
