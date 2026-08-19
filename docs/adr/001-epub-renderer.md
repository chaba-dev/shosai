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
the reported replacement size proves geometry, and the visual observation
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
| CSS/table/MathML fidelity  | Promising on macOS system WebKit                                                                              | Unknown                                                         | Combined fixture on every target                       |
| Sandbox and offline policy | macOS and Linux/X11 hostile-content proofs record zero network connections; deny handlers configured; CSP/navigation tested | Smaller surface, resource policy incomplete                     | Repeat proof on Windows; resource limits               |
| Iced integration           | Measured bounds, resize, focus/visibility method returns, observed replacement size, lifecycle and ordinary-close teardown proven on macOS; measured bounds, resize, and lifecycle teardown proven on headless Linux/X11; still outside widget composition | Natural widget composition                                      | Actual focus/visibility, scale, overlay, clipping, real tabs, IME, other targets |
| Accessibility/selection    | Unknown platform behavior                                                                                     | Not currently modeled                                           | Screen-reader and selection tests                      |
| Portability                | macOS and x86_64 X11 paths proven; Wayland blocker and platform runtimes differ                                | Existing Iced targets                                           | Windows, Linux arm64, interactive X11, native Wayland  |
| Warm page-turn latency     | Unknown                                                                                                       | Release p50 0.34–2.81 ms, p95 1.20–6.31 ms on the baseline host | Equivalent Wry and cross-platform measurements         |
| Packaging cost             | WebKitGTK added on Linux                                                                                      | Dependency set not selected                                     | Binary/runtime/package smoke tests                     |
| Maintenance cost           | Browser integration and platform variance                                                                     | CSS/layout implementation scope                                 | Native component/dependency prototype                  |

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

## Native performance baseline

The dated
[2026-08-17 EPUB page-turn benchmark](../../benchmarks/epub-page-turn/2026-08-17/)
records the synthetic app-action-to-compositor-present protocol, reproducible
workloads, host details, budgets, and complete native baseline. All measured
paths met their initial budgets; large-text relayout was the dominant native
cost.

## Next spike steps

1. Exercise scale changes, invalid-bounds visibility, overlays, tabs, focus,
   IME, accessibility behavior, and ordinary close teardown on macOS.
2. Run the same child and hostile-content spikes on Windows and Linux arm64,
   and complete interactive Linux/X11 input/accessibility checks. Decide whether
   lack of a viable Wayland host rejects Wry or justifies a documented backend
   fallback.
3. Build the native computed-style boundary for the same table/font/MathML/RTL
   fixture, inventory maintained permissive selector/layout/math dependencies,
   and estimate unsupported work explicitly.
4. Run the same release performance protocol for Wry and on the other released
   platforms before assigning final comparison scores or choosing a renderer.

## Decision

No renderer selected. Gate 0 remains open.
