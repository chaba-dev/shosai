# Theme mapping evidence (package 2C)

Evidence for package 2C, "shared tokens, Rust theme mapping, `app_theme.dart`,
paint palettes" ([restoration plan](../flutter-ui-restoration-plan.md) stage 2,
[reference specification](../../../docs/flutter-ui-reference-spec.md) rows
`XA-04`, `XA-05`, `XA-11`, `LB-23`).

- Base revision: `2473383965179e05c4155d228e41fc94e923da55` (#121).
- Pinned Iced reference: `1e54270a6bb24f15630ece336a0575bdbe5be113` (#108).
- Recorded: 2026-09-22, runner `framework16`, Linux (FreeType) rendering.
- **Linux candidates approved by the owner on 2026-09-23** and installed as the
  Linux baselines; see [Approval](#approval) for the exact scope.
- Machine-readable record: [`manifest.json`](manifest.json).

## What is in this directory

| Path | Contents |
| --- | --- |
| `palette/` | The `2C-PALETTE` renders: the library under the application light and retained dark palettes, and the reader under the light, dark and sepia document palettes. Each render asserts the palette the tree actually used before it is captured. |
| `candidates/linux/` | The 13 approved Linux goldens for the baselines the mapping changes. The same bytes are installed in `flutter/test/goldens/`; no regeneration was performed. |
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

## Approval

The owner reviewed the palette and candidate previews and approved the **13 exact
Linux candidates** committed under `candidates/linux/` on **2026-09-23**, for the
**theme mapping only**. The scope is deliberately narrow:

- It covers the mapped palette, type, radii and the affected surfaces in those 13
  renders. It is **not** Iced parity approval, and not approval of the current
  `Open document`/path panel composition: that panel is the current Flutter UI
  and is replaced in stage 4B.
- It does **not** resolve macOS: the nine `flutter/test/goldens/macos/` baselines
  still need their own render verification and owner review, and the macOS
  verifier run stays identified by revision `f867caed`, which predates this
  baseline-only delta.
- The native macOS picker smoke from 2B remains open.

Installation was a byte copy of the approved candidates: every installed file
matches its `candidate_sha256` in `manifest.json` (verified for all 13), and no
image was regenerated.

## Candidate verification

| Step | Command | Result |
| --- | --- | --- |
| Superseded baselines | `flutter test` | 381 passed, 13 failed — all 13 are the golden pixel comparisons listed above |
| Candidates installed | `flutter test --update-goldens test/product_shell_test.dart test/visual/production_shell_golden_test.dart test/visual/render_structure_test.dart` | 66 passed |
| Candidates re-checked | the same three files without `--update-goldens` | 66 passed |
| Approved bytes installed | `flutter test` | 394 passed, 0 failed |
| Render reproduction | harness drift records | nine harness renders report 0 differing pixels, 0 changed blocks; `repeat-render-900` is byte-identical across two fresh renders |

The failing-before-candidate run is preserved separately in
`manifest.json.test_results.flutter_full_against_superseded_baselines`. Before
approval the superseded goldens were restored and re-hashed to confirm they were
byte-identical to the base revision; after approval the installed baselines were
re-hashed against the candidate hashes.

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

## macOS verification (independent, pending approval)

The macOS verifier thread completed its render verification at revision
`f867caed7f13c986e894b7298a0586e7570af8f2` (the head before this baseline-only
delta): 383 passed, 9 failed — all nine are golden pixel comparisons against the
unchanged macOS baselines — and 2 skipped, with 17 renders per run and
byte-identical SHA-256 manifests across two runs. With the nine candidates
installed in a disposable clone: 392 passed, 0 failed, 2 skipped, and the
failures return when the approved files are restored.

**macOS appearance approval is not granted and nothing macOS-related is
committed here.** The nine candidate hashes are recorded in
`manifest.json.macos_verification` as pending owner review, together with the
verifier's findings (the approved-to-candidate diff structure matches the Linux
evidence for all nine names, platform drift is unchanged by the mapping, an
ink-profile shift analysis shows best shift +0 in every non-degenerate strip,
and the reader-pdf changed-block count is the known ink-mask boundary effect).
Because this approval commit creates a new head, the verifier requires a fresh
pass on that head before macOS approval.

## Limits

- The nine macOS baselines under `flutter/test/goldens/macos/` are unchanged and
  cannot be produced on Linux; a macOS run has to render, review and approve its
  own candidates before that platform is resolved. The verifier's run stays
  identified by revision `f867caed`, before this baseline-only delta.
- These are Linux FreeType renders. macOS rasterisation differs and is reviewed
  per platform, per the 2B golden policy.
- The native macOS picker smoke from 2B remains open; this package makes no
  macOS validation claim.
