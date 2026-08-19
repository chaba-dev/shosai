# ADR 001: EPUB renderer

- Status: Investigating (Gate 0)
- Date: 2026-08-17
- Plan: [001 Enhanced EPUB Rendering](../plans/001-enhanced-epub-rendering.org)

## Context

Shōsai needs better EPUB CSS, table, embedded-font, MathML, navigation, and
accessibility fidelity without turning its native renderer into an unbounded
browser implementation. Gate 0 compares two routes:

1. embed an operating-system webview through `wry`;
2. expand the native parser, computed-style, layout, and Iced presentation.

This record is intentionally not a decision yet. It captures reproducible spike
evidence and keeps unknowns visible until both routes render the same fixtures.

## Current spike harness

The Wry harness is isolated from production behind an optional Cargo feature:

```sh
cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
SHOSAI_WRY_SPIKE_PAGE=conformance \
  cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
SHOSAI_WRY_SPIKE_NETWORK_PROOF=1 \
  cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
SHOSAI_WRY_SPIKE_LIFECYCLE_PROOF=1 \
  cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
SHOSAI_WRY_SPIKE_OVERLAY_PROOF=1 \
  cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
SHOSAI_WRY_SPIKE_BOUNDS_PROOF=1 \
  cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
SHOSAI_WRY_SPIKE_OVERLAY_OBSERVATION=1 \
  cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
cargo test -p shosai-app --example epub-wry-spike --features epub-wry-spike
```

On Linux the harness is deliberately an X11-only spike. The Nix development
shell supplies GTK 3 and WebKitGTK 4.1; force both Iced/winit and GTK onto X11
so a Wayland session cannot be mistaken for native Wayland support:

```sh
env -u WAYLAND_DISPLAY -u WAYLAND_SOCKET GDK_BACKEND=x11 \
  cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
env -u WAYLAND_DISPLAY -u WAYLAND_SOCKET GDK_BACKEND=x11 SHOSAI_WRY_SPIKE_NETWORK_PROOF=1 \
  cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
env -u WAYLAND_DISPLAY -u WAYLAND_SOCKET GDK_BACKEND=x11 SHOSAI_WRY_SPIKE_LIFECYCLE_PROOF=1 \
  cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
```

Without those backend settings, a native Wayland GTK display or a non-Xlib
Iced parent is rejected with an explicit diagnostic. This is a feasibility
boundary, not a compatibility fallback.

It currently proves on macOS arm64 that:

- Iced 0.14's public `window::run` callback exposes a parent window handle that
  Wry 0.56.1 can use to build a child `WKWebView`;
- an in-memory `shosai:` custom protocol can render a chapter containing CSS,
  a table with `rowspan`, and presentation MathML;
- the same protocol now opens the checked-in `sample.epub` from bytes and serves
  every available manifest resource, including spine and navigation XHTML,
  stylesheet, and image bytes, using manifest media types; every protocol
  request is recorded by the harness;
- an Iced widget operation reports the real placeholder container's logical
  bounds and the child is created in those bounds;
- the automated lifecycle mode resizes the Iced window, requires a changed
  placeholder measurement and successful Wry bounds update, checks the reported
  logical child size, invokes child focus, parent focus, hide, and show methods
  and requires each to return `Ok`, then destroys and recreates the child and
  checks the replacement's reported logical size before final teardown and
  parent close; it exits nonzero if any observable step fails or the sequence
  does not complete within ten seconds;
- a macOS visual observation mode places a full-window Iced `Stack` modal over
  the reader without coordinating the native child.  The chapter remains
  visible above the modal and completely obscures the modal where their bounds
  intersect, confirming that Iced draw order cannot cover the child `WKWebView`;
- the automated macOS overlay mode activates the same modal, requires the
  current child generation's Wry hide call to return `Ok`, holds the modal for
  one second, dismisses it, then destroys the hidden child and recreates it at
  the latest measured logical bounds without re-showing the hidden child during
  intermediate geometry events. It checks the replacement's reported logical
  size before final teardown and rejects stale generation callbacks, missing
  child state, failed calls, and timeouts.  Destroy/recreate is deliberate: in
  the spike, showing a child again after a settled hide returned from Wry but
  left Iced without subsequent proof progress; an in-place visibility restore is
  therefore not treated as viable evidence;
- the automated macOS bounds mode collapses the Iced placeholder to zero
  height and requires the widget operation to report no usable placeholder,
  requires the current child generation's hide call to return `Ok`, destroys
  the hidden child, restores the placeholder, and recreates the child at the
  newly measured logical bounds.  It verifies the replacement's reported size
  and fails on stale generations, stale measurement epochs, failed calls,
  missing children, close, or timeout;
- content JavaScript is disabled, navigation is allowlisted to the book
  protocol, downloads and new windows are denied, and a restrictive CSP is
  attached to protocol responses;
- the automated hostile-content mode loads remote CSS imports, images, fonts,
  frames, objects, and external/inline scripts against a controlled loopback
  listener, requires the exact hostile resource to be served and finish loading,
  then waits through a grace period.  It exits nonzero for any connection,
  listener error, worker panic, wrong/missing page load, or missing protocol
  response.  A control test proves that a direct connection is detected.

The successful macOS rendering run was visually checked, and the automated
network and measured-bounds lifecycle proofs pass on macOS arm64. Checked-in
book resources are served with their exact manifest media types, including
`application/xhtml+xml`; the generated conformance page remains explicitly
declared as `text/html` because it is harness-owned rather than an EPUB manifest
resource.

The focus and visibility results prove only that Wry's methods returned `Ok`;
the reported replacement size proves only its logical size, not placement or
visual restoration, and the visual observation
proves the uncoordinated z-order failure.  They do not prove a visually correct
restored frame after modal dismissal. Wry's macOS
implementation does not expose AppKit's boolean first-responder result. They do
not prove that focus changed, keyboard/IME events route correctly, or that the
restored visual result matches Iced composition. The harness remeasures on
scale-factor events, but that path is not yet exercised evidence and remains
open alongside clipping, real tab switching, IME, and accessibility tests.
Ordinary close cleanup is
exercised separately on macOS: with Iced's automatic close exit disabled, UI
automation clicked the native close button and the handler recorded that it
dropped the live child before explicitly closing the parent.

On Linux x86_64, the harness compiles against GTK 3.24.51 and WebKitGTK 4.1
(2.50.6) in the Nix development shell. Under Xvfb/X11, the same automated
measured-bounds resize/teardown proof passes and the hostile-content proof
serves the expected page while recording zero book-initiated network
connections. The harness installs Wry's documented winit X11 error hook for
the benign WebKit `GLXBadWindow` error 170 and accepts `BadWindow` only after
the one-shot harness explicitly begins teardown, when GTK can destroy the XIM
child before winit's cleanup operations; without those cases, the lifecycle
runs panic during resize or teardown. These headless runs prove the X11 child
lifecycle and resource policy, not focus/input, accessibility, visual fidelity,
hardware scaling, Linux arm64, or native Wayland behavior.

## Integration findings

Iced has no supported native-child widget abstraction. A production Wry route
would need an Iced placeholder plus application-owned platform state to:

- synchronize bounds, clipping, visibility, scale factor, focus, IME, overlays,
  tab switches, and teardown;
- keep Wry objects on the UI thread while communicating lifecycle results back
  through Iced messages;
- map DOM locations to stable EPUB chapter/fragment/text anchors.

Native children normally sit above Iced's GPU surface. Menus, search UI,
bookmarks, and dialogs cannot be assumed to overlay or clip the child correctly.
Those behaviors need explicit tests rather than visual inference.

## Platform and packaging findings

| Target        | Child-view path                            | Current finding                                                                                                                 |
|---------------|--------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------|
| macOS 12+     | Iced raw AppKit handle → child `WKWebView` | Builds and renders with the system WebKit; no extra runtime packaged                                                            |
| Windows CI    | Iced raw Win32 handle → child WebView2     | API path exists; runtime, accessibility, focus, and CI spike not yet tested                                                     |
| Linux X11     | Iced raw Xlib handle → WebKitGTK child     | Builds on x86_64; automated resize/teardown and zero-network proofs pass under Xvfb; interactive and arm64 evidence remain open |
| Linux Wayland | GTK container via Wry Unix extension       | Raw child embedding is unsupported; standard Iced runner exposes no GTK container, making this the main Wry portability blocker |

Wry 0.56.1 is Apache-2.0 OR MIT and uses system engines. A full transitive
license report and notices check remains required. Windows is tested in CI but
is not currently a release artifact, so build support and shipped support must
not be conflated.

The current support boundary is now explicit:

- release artifacts ship for Linux x86_64, Linux arm64, and macOS arm64;
- CI runs the workspace tests on Linux, macOS, and Windows, but no Windows
  artifact is published;
- the Nix package closes over Iced's X11 and Wayland runtime libraries, but the
  published Linux tarballs are a separate format: they bundle PDFium and rely
  on compatible host X11/Wayland graphics libraries. Neither distribution path
  currently includes WebKitGTK;
- the selected production renderer must therefore work in the shipped macOS
  and Linux artifacts, including both X11 and Wayland sessions. It must compile
  and retain backend-independent core tests on Windows; shipping a Windows
  renderer is deferred until Shōsai publishes a Windows artifact.

A Wry-only implementation does not currently satisfy that boundary because it
has no child-view path in Shōsai's Wayland host and would add an unbundled
WebKitGTK runtime to Linux. Gate 0 may still select Wry only if the spike proves
a maintainable Wayland integration or defines and evaluates a native fallback;
silently disabling EPUB rendering on a shipped session type is not acceptable.

Authoritative implementation references:

- [Wry `WebViewBuilder`](https://docs.rs/wry/0.56.1/wry/struct.WebViewBuilder.html)
- [Wry platform considerations](https://docs.rs/wry/0.56.1/wry/#platform-considerations)
- [Iced `window::run`](https://docs.rs/iced/0.14.0/iced/window/fn.run.html)

## Comparison matrix

Scores remain unset until the same fixture and measurement protocol is used.

| Criterion                  | Wry route                                                                                                     | Native route                                                    | Evidence still needed                                  |
|----------------------------|---------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------|--------------------------------------------------------|
| CSS/table/MathML fidelity  | Promising on macOS system WebKit                                                                              | Test-only cascade, shaping, block-box, and normalized Grid table prototypes pass semantic assertions; CSS inline and table algorithms, EPUB font loading, CJK/emoji font coverage, and MathML rendering remain absent | Combined rendered fixture on every target              |
| Sandbox and offline policy | macOS and Linux/X11 hostile-content proofs record zero network connections; deny handlers configured; CSP/navigation tested | Smaller surface, resource policy incomplete                     | Repeat proof on Windows; resource limits               |
| Iced integration           | Measured bounds, resize, focus/visibility method returns, observed replacement size, lifecycle and ordinary-close teardown proven on macOS; measured bounds, resize, and lifecycle teardown proven on headless Linux/X11; still outside widget composition | Natural widget composition                                      | Actual focus/visibility, scale, overlay, clipping, real tabs, IME, other targets |
| Accessibility/selection    | Unknown platform behavior                                                                                     | Shaped clusters retain logical source ranges; selection and accessibility are not modeled | Hit-testing, screen-reader, and selection tests        |
| Portability                | macOS and x86_64 X11 paths proven; Wayland blocker and platform runtimes differ                                | Existing Iced targets                                           | Windows, Linux arm64, interactive X11, native Wayland  |
| Warm page-turn latency     | Unknown                                                                                                       | Release p50 0.34–2.81 ms, p95 1.20–6.31 ms on the baseline host | Equivalent Wry and cross-platform measurements         |
| Packaging cost             | WebKitGTK added on Linux                                                                                      | `cosmic-text` is already present through Iced; test-only Taffy candidate is pure Rust but not selected for production | Font and remaining dependency size; package smoke tests |
| Maintenance cost           | Browser integration and platform variance                                                                     | Selector/cascade, shaping, block-leaf measurement, and explicit table-grid lowering boundaries are feasible, but CSS inline/table compatibility plus font/MathML layout remains substantial | Native font/math dependency prototypes                 |

## Fixture and measurement matrix

Every fixture must be generated from redistribution-safe inputs. Isolated books
identify failures precisely; `conformance.epub` combines the fidelity cases to
expose cascade, resource, and pagination interactions. Semantic assertions are
required in automated tests. Screenshots are supporting evidence only and must
use fixed fonts, viewport, theme, and backend versions.

| ID                 | Fixture content                                                                                                                          | Required assertion                                                                                                                                            |
|--------------------|------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `baseline`         | Existing `sample.epub`                                                                                                                   | TOC, chapter navigation, search offsets, bookmarks, progress, themes, and both reader modes remain stable                                                     |
| `nested-image`     | Block and `<p><img></p>` images, figure/caption, missing image, image in a table cell                                                    | Every local image resolves relative to its chapter, nested images are not dropped, captions remain associated, and missing content has deterministic fallback |
| `css-cascade`      | Element/class/compound/descendant selectors, specificity ties, source order, inheritance, inline style, relative lengths, `display:none` | Computed values and fallback match the documented supported CSS subset without leaking reader overrides                                                       |
| `table`            | Caption, header groups, nested content, links/images, `colspan`, `rowspan`, narrow and over-wide tables                                  | Cell and header structure is preserved; pagination and overflow never flatten or silently discard content                                                     |
| `fonts`            | Local WOFF, WOFF2, TTF, and OTF faces; weight/style variants; missing/corrupt source; same family in two books                           | Only in-archive fonts load, fallback is deterministic, variants map correctly, and per-book registrations are released                                        |
| `mathml`           | Inline/display fractions, roots, scripts, operators, matrix, annotations, malformed markup                                               | Math remains legible at each font size/theme and exposes readable fallback without scripts or remote assets                                                   |
| `bidi`             | RTL paragraphs and lists, Arabic/Hebrew with Latin/numbers, combining marks, emoji and CJK                                               | Visual order, shaping, wrapping, search offsets, selection, and navigation retain logical text order                                                          |
| `links`            | Same-chapter and cross-chapter fragments, percent-encoded paths, HTTP(S), mail, and unsupported schemes                                  | Internal targets restore a stable logical location; external targets follow the explicit user policy and never navigate the book view implicitly              |
| `malformed-markup` | Recoverable and fatal XHTML/CSS, deep nesting, missing spine/resource entries                                                            | Failures are bounded and diagnosed by chapter/resource; one bad resource does not abort unrelated readable chapters                                           |
| `canonical-paths`  | `.`/`..`, encoded traversal, query/fragment, case variants, duplicate normalized entries, absolute and foreign schemes                   | One canonical resolver rejects traversal/aliasing and never serves outside the EPUB origin                                                                    |
| `remote-content`   | Remote image/font/CSS imports, redirects, scripts, popups, downloads, forms, and navigation attempts                                     | Automated request recording proves zero book-initiated network requests and zero script execution                                                             |
| `resource-limits`  | Excess entries, high compression ratio, oversized entry/aggregate XML/text, huge declared/decoded images and fonts                       | Configured limits fail before unbounded allocation or backend decoding and produce actionable diagnostics                                                     |
| `conformance`      | All fidelity cases above in a multi-chapter book                                                                                         | Both candidate renderers run the same navigation, layout, accessibility, resource, and screenshot protocol                                                    |
| `performance`      | Existing sample plus generated large text/image workloads                                                                                | Warm turn, chapter transition, relayout, load, and memory measurements use equivalent release protocols on each candidate                                     |

The commercial EPUB that exposed missing `<p><img></p>` diagrams and flattened
tables is evidence for `nested-image` and `table`, but is not redistributable and
must not be checked in. The generated cases reproduce those structures without
copying its content.

## Native computed-style spike

The test-only native spike parses the redistribution-safe
`native-computed-style.xhtml` and CSS fixture with the existing `roxmltree` and
`lightningcss` dependencies. It computes styles before `ContentNode` lowering
without changing the class-only production renderer. Semantic tests prove:

- type, class, ID, compound, child, descendant, adjacent-sibling, and
  general-sibling matching, plus selector specificity and source order;
- author `!important` ordering, inline style precedence, inherited text
  properties, independently exercised `dir` and CSS direction, and UA defaults
  for headings, code, captions, row groups, rows, and table cells;
- `em`, `rem`, `px`, `pt`, and font-percentage resolution, including margins
  resolved against the element's computed font size;
- preservation of table, namespaced MathML fraction/identifier structure,
  mixed Arabic/Latin/Japanese text, and one `@font-face` rule in the parsed
  inputs. This is structural evidence only: it does not shape mixed-script
  text, load the font, lay out table cells, or render MathML.

The prototype deliberately reports unsupported selectors, rule kinds, and
property/value pairs rather than applying them approximately. The fixture
proves that a matching `:nth-child` selector and declarations inside `@layer`
are withheld and reported. Percentage margins remain unresolved until layout
provides a containing-block width; relative `bolder`/`lighter` weights and
unrepresented `display` values are likewise reported and inherited/default
values remain intact. `text-align: match-parent` is resolved from the parent's
alignment and direction. Attribute/nth/dynamic pseudo-class, namespace,
nesting, conditional-rule evaluation, and full property/value handling remain
outside this bounded matcher.

Dependency inspection found that `lightningcss` exposes its parsed selector AST
but keeps its `parcel_selectors::SelectorImpl` private, so the generic
`parcel_selectors` matcher cannot be connected directly to `roxmltree`.
Production would need either a separately parsed public `parcel_selectors`
implementation, a maintained DOM/CSS engine, or an explicitly bounded custom
matcher. `lightningcss` and `parcel_selectors` are MPL-2.0; `roxmltree` is
MIT/Apache-2.0. The repository already receives `cosmic-text`
transitively through Iced, but it supplies shaping rather than CSS, block/table
layout, pagination, selection/accessibility, or MathML. The follow-up Taffy
prototype fills only block-box placement around externally measured leaves; no
single current dependency fills the remaining layers, so the native route
remains a high and potentially unbounded implementation/maintenance commitment.

## Native text-shaping spike

A test-only `cosmic-text` 0.15.0 spike shapes fixed strings with an in-memory,
host-independent font database. The direct dev dependency pins the same version
already selected transitively by Iced. Semantic tests prove that:

- advanced shaping handles Arabic, Hebrew, and mixed Latin/RTL text, exposes
  bidi levels and visual positions, and retains each glyph cluster's logical
  UTF-8 byte range;
- line-local byte ranges can be rebased to chapter-global byte and Unicode-
  scalar offsets currently used by EPUB search, including non-ASCII text before
  a line break, without deriving logical order from visual glyph order; line
  endings remain explicit unshaped separators;
- combining marks form a multi-scalar cluster, while CJK and an emoji ZWJ
  sequence retain complete logical source coverage;
- a deterministic in-memory fallback set repeatedly selects Inter for Latin and
  Noto Sans Arabic/Hebrew for every corresponding script cluster with nonzero
  glyph IDs;
- the Inter fixture exposes a `wght` axis and regular/bold shaping produces
  different advances, while italic requests select the italic face;
- fixed fonts, locale, metrics, and width produce repeatable glyph measurements,
  wrapping, baselines, and line heights.

The fixtures are the unmodified Inter variable/italic and Noto Sans
Arabic/Hebrew fonts distributed with `cosmic-text`; their complete SIL OFL 1.1
notices are checked in beside them. `cosmic-text` itself is MIT OR Apache-2.0.
The fixtures deliberately lack CJK and emoji fonts, so those cases prove source
range behavior, not readable glyph coverage or correct emoji composition. A
production font policy must provide and bound suitable platform or EPUB-local
fallbacks and test missing/corrupt fonts and per-book cleanup.

This does not make the current paginator shaping-aware. Its scalar-count and
`0.55em` width heuristics can still split grapheme/ZWJ sequences and cannot use
these measurements. The spike rebases `LayoutGlyph`'s line-local UTF-8 offsets,
but production must preserve the normalized chapter/span bases and inserted
separators used by search; shaping arbitrary DOM substrings cannot reconstruct
those locations afterward. Stable DOM/chapter locations, hit testing, selection
geometry, accessibility semantics, inline box construction, production block/
table/image layout, pagination, and MathML remain separate unimplemented
components. The spike therefore establishes a viable shaping primitive and
interface evidence, not a production native renderer. The direct test-only
`ttf-parser` check used to inspect the variable axis is also MIT OR Apache-2.0.

## Native block/inline layout spike

A test-only Taffy 0.13.0 prototype treats each paragraph-like anonymous inline
root as a leaf measured by the existing `cosmic-text` fixture shaper. A bounded
input structure mirrors already-proven computed values without connecting the
two private test modules or changing production pagination. Tests prove that:

- Taffy's block algorithm applies fixed inline-axis margins, stacks text leaves,
  collapses adjoining positive block margins, and removes `display:none` leaves
  with nonzero margins from sibling flow;
- computed font size, line height, alignment, and inline bold/italic runs reach
  `cosmic-text`; size and alignment change observable glyph geometry, and the
  measured lines determine the leaf height at Taffy's width;
- mixed Latin/Arabic/Hebrew glyph ranges remain chapter-global through block
  placement. A neutral bidi separator for which the rich-text layout emits no
  glyph is retained explicitly as unshaped source rather than silently lost;
- a replaced-image leaf is constrained to the available width while preserving
  its intrinsic ratio; and
- fixed inputs, fonts, viewport, and disabled pixel rounding produce repeatable
  same-process block, line, and glyph geometry on each tested target.

Taffy is MIT-licensed, pure Rust, and the block spike enables its `std`, `alloc`,
tree, and block-layout features. The later table spike also enables Grid. These
paths activate ArrayVec 0.7.6 (MIT OR Apache-2.0), SlotMap 1.1.1 (Zlib), and,
for Grid, SmallVec 1.15.1 (MIT OR Apache-2.0); all three versions were already
present in the workspace lockfile, and notice/package consequences begin only
if Taffy is promoted from a dev dependency. Serde is not enabled by this
feature set.
Taffy's block implementation accepts externally measured leaves and implements
margin collapse, but it deliberately has no CSS inline formatting context or
table algorithm. Shōsai would still need to build anonymous inline roots,
collapse/preserve CSS whitespace, position inline replaced boxes, combine
baselines, and retain per-line geometry for painting, hit testing, selection,
and fragmentation. [Taffy's style model](https://docs.rs/taffy/0.13.0/taffy/style/struct.Style.html)
exposes only block/flow-root/none in this feature set.

The spike also does not connect CSS `direction` to `cosmic-text` paragraph base
direction: Taffy's direction affects its box algorithm while `cosmic-text`
infers bidi direction from text. Explicit CSS direction, logical margins,
nested blocks, min/max-content fidelity, floats, inline images, tables,
pagination, and accessibility remain unproven. The bounded bridge explicitly
rejects Taffy min-content text queries rather than returning zero-width shaping,
and rejects more than one Unicode bidi paragraph per anonymous inline-root leaf
rather than rebasing against a different line splitter. Separators remain
explicit unshaped source. Taffy may measure a text leaf multiple times, so a
production bridge would require shared font state and a width-keyed shaping/
layout cache. Same-process repetition does not establish cross-run or
cross-target numeric equality. Blitz demonstrates a maintained
[Taffy/Stylo/Parley integration](https://github.com/DioxusLabs/blitz), but it is
a substantially larger HTML/CSS stack, uses Parley rather than the proven
`cosmic-text` path, and was not added by this spike. This remains component
feasibility evidence, not a production layout implementation.

## Native table-layout spike

A redistribution-safe test-only XHTML fixture normalizes one explicit table
into caption metadata, row groups, headers, occupied row/column coordinates,
`rowspan`/`colspan`, links, and image source/fallback/intrinsic dimensions. The
adapter lowers the cells to direct children of a Taffy Grid container and uses
the bundled `cosmic-text` fonts for cell measurement. Tests prove that:

- caption, header/body/footer group identity, header cells, spans, an internal
  link, and a nested image remain represented after normalization;
- explicit Grid placement gives spanning cells the expected combined row and
  column geometry while constrained text contributes measured row height;
- the bounded measurement adapter distinguishes whitespace-delimited minimum
  content from unwrapped maximum content and keeps intrinsic image dimensions;
  and
- a 360 px table minimum overflows a 240 px viewport without flattening or
  discarding cells, leaving scrolling or other presentation to a caller.

This establishes a possible explicit-grid lowering boundary, not browser table
compatibility. Taffy 0.13.0 states that it does not implement table layout; its
Grid track sizing differs from CSS automatic/fixed table algorithms, especially
for intrinsic and spanning-cell width distribution. The fixture uses equal
explicit tracks and a whitespace-delimited minimum-content approximation. It
does not implement anonymous table-box repair, `colgroup`, caption placement
variants, collapsed-border conflict resolution, baseline alignment, writing
modes, painting, hit testing, selection, accessibility header associations, or
fragmentation/repeated headers. The adapter is not connected to the computed
style or production `ContentNode` paths, and its inline image evidence does not
yet position an image among shaped glyphs. Promoting this route would therefore
require a documented EPUB table subset or a fuller maintained table algorithm;
Grid alone cannot justify browser-equivalent fidelity.

## Native performance baseline

The dated
[2026-08-17 EPUB page-turn benchmark](../../benchmarks/epub-page-turn/2026-08-17/)
records the synthetic app-action-to-compositor-present protocol, reproducible
workloads, host details, budgets, and complete native baseline. All measured
paths met their initial budgets; large-text relayout was the dominant native
cost.

## Next spike steps

1. Exercise scale changes, invalid-bounds visibility, overlays, tabs, focus,
   IME, and accessibility behavior on macOS. Ordinary close teardown is already
   proven separately.
2. Run the same child and hostile-content spikes on Windows and Linux arm64,
   and complete interactive Linux/X11 input/accessibility checks. Decide whether
   lack of a viable Wayland host rejects Wry or justifies a documented backend
   fallback.
3. Extend the native component evidence with inline-tree construction, a fuller
   table compatibility boundary, EPUB font loading, selection/accessibility,
   pagination, and MathML, then render the same fixture. Treat every test-only
   prototype as evidence, not a production implementation.
4. Run the same release performance protocol for Wry and on the other released
   platforms before assigning final comparison scores or choosing a renderer.

## Decision

No renderer selected. Gate 0 remains open.
