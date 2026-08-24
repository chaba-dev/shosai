# ADR 001: EPUB renderer

- Status: Accepted — native renderer selected
- Date: 2026-08-17
- Decision date: 2026-08-21
- Plan: [001 Enhanced EPUB Rendering](../plans/001-enhanced-epub-rendering.org)

## Context

Shōsai needs better EPUB CSS, table, embedded-font, MathML, navigation, and
accessibility fidelity without turning its native renderer into an unbounded
browser implementation. Gate 0 compares two routes:

1. embed an operating-system webview through `wry`;
2. expand the native parser, computed-style, layout, and Iced presentation.

This record preserves the spike evidence that led to the decision. Native
rendering is the production route; the Wry harness remains an optional research
and comparison tool, not a production backend or fallback.

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
SHOSAI_WRY_SPIKE_VISUAL_PROOF=1 \
  cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
SHOSAI_WRY_SPIKE_BOUNDS_PROOF=1 \
  cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
SHOSAI_WRY_SPIKE_SCALE_PROOF=1 SHOSAI_WRY_SPIKE_SCALE_TARGET=-1800,100 \
  cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
SHOSAI_WRY_SPIKE_INPUT_PROOF=1 \
  cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
SHOSAI_WRY_SPIKE_CLIPBOARD_PROOF=1 \
  cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
SHOSAI_WRY_SPIKE_TAB_PROOF=1 \
  cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
SHOSAI_WRY_SPIKE_READER_PROOF=1 \
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
env -u WAYLAND_DISPLAY -u WAYLAND_SOCKET GDK_BACKEND=x11 SHOSAI_WRY_SPIKE_INPUT_PROOF=1 \
  cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
env -u WAYLAND_DISPLAY -u WAYLAND_SOCKET GDK_BACKEND=x11 SHOSAI_WRY_SPIKE_CLIPBOARD_PROOF=1 \
  cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
env -u WAYLAND_DISPLAY -u WAYLAND_SOCKET GDK_BACKEND=x11 SHOSAI_WRY_SPIKE_READER_PROOF=1 \
  cargo run -p shosai-app --example epub-wry-spike --features epub-wry-spike
```

Without those backend settings, a native Wayland GTK display or a non-Xlib
Iced parent is rejected with an explicit diagnostic. This is a feasibility
boundary, not a compatibility fallback.

Current evidence:

- Iced 0.14's public `window::run` callback exposes a parent window handle that
  Wry 0.56.1 can use to build a child `WKWebView`;
- an in-memory `shosai:` custom protocol can render a chapter containing CSS,
  a table with `rowspan`, and presentation MathML;
- the same protocol now opens the checked-in `sample.epub` from bytes and serves
  every available manifest resource, including spine and navigation XHTML,
  stylesheet, and image bytes, using manifest media types; every protocol
  request is recorded by the harness;
- an automated reader-integration mode serves only a host-owned XHTML fixture
  and injects a trusted controller. On the 2026-08-19 Linux/X11 host it verified
  dark-theme colors and a 24 px reader font, followed a real internal fragment
  link, highlighted one exact text match with a `mark`, produced multiple CSS
  columns in paginated mode, restored continuous flow, and retained the same
  canonical chapter path, fragment, and chapter text offset across the DOM
  mutation and mode changes. The recorded location was
  `_spike/reader.xhtml#section-two` at chapter text offset 503; no scroll or
  pixel coordinate is part of that model. WebKitGTK suppresses initialization
  scripts when Wry disables JavaScript globally, so this mode enables JavaScript
  only for the host fixture while its CSP denies page scripts. Ordinary and
  hostile EPUB pages keep Wry's JavaScript disable setting;
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
- an automated macOS visual-restoration mode captures the composited Iced/Wry
  window through its current Core Graphics window number rather than an
  unobscured desktop region. A host-owned XHTML fixture renders an exact
  `#2468ac` marker; the proof requires that marker in the initial capture,
  requires zero matching pixels after hiding the current child under the Iced
  modal, recreates the child, and requires the restored marker's backing-pixel
  bounds and count to match within two pixels and one percent. It also requires
  unchanged capture dimensions and integral backing scale, ignores stale child
  generations, bounds every System Events/Core Graphics/screen-capture
  subprocess, requires exact-zero hidden marker evidence, and fails if temporary
  capture cleanup cannot complete. On the 2026-08-20 macOS arm64
  host, the rotated 2× DELL U2720QM run captured a 3364×5954 backing-pixel
  window. Initial and restored marker bounds were both
  `[841,1699]-[2522,4535]` with 4,771,834 marker pixels; the hidden capture had
  zero marker pixels. This establishes visually correct restoration for that
  arrangement only. The available 1× external, ordinary 2× external, and
  built-in Retina arrangements have not yet run this proof, so the broader
  physical-pixel/display matrix remains open;
- the automated macOS bounds mode collapses the Iced placeholder to zero
  height and requires the widget operation to report no usable placeholder,
  requires the current child generation's hide call to return `Ok`, destroys
  the hidden child, restores the placeholder, and recreates the child at the
  newly measured logical bounds.  It verifies the replacement's reported size
  and fails on stale generations, stale measurement epochs, failed calls,
  missing children, close, or timeout;
- the automated macOS scale mode queries the initial Iced window scale, moves
  the parent to explicitly configured desktop coordinates, requires a changed
  `Rescaled` event and a matching scale query, then requires a fresh Iced
  placeholder measurement before updating the current-generation child and
  re-queries the scale before accepting success.
  On the 2026-08-19 macOS arm64 host, moving from the main 2× display to the
  display at `-1800,100` produced a 2→1 transition; Iced remeasured the same
  900×588 logical placeholder and Wry accepted those logical bounds and
  reported the same logical child size. The proof rejects unchanged or
  unconfirmed scale values, stale generations and measurement epochs,
  unusable bounds, premature shared synchronization, failed Wry calls, missing
  children, close, and timeout;
- the macOS input mode serves a harness-owned input page, injects only a
  trusted host script while its CSP denies page scripts, focuses the
  child and its DOM input, and requires ordered focus, keydown, and exact-value
  IPC observations before asking Wry to focus the parent and waiting for a new
  Iced keyboard event. On the 2026-08-19 macOS arm64 host, UI automation typed
  the exact `shosai-input-proof` token and the child reported every keydown and
  input value. After `focus_parent`, AppKit inspection confirmed that the exact
  Iced/winit `NSView` from the raw parent handle was already the window's first
  responder, so the direct AppKit fallback was not invoked. After a 250 ms
  queued-event drain and Iced's window-focus request, a fresh automated key
  produced an Iced keyboard event and the proof passed. This supersedes the
  earlier timeout-only inference: the public Wry handoff works on this host;
  the harness had not established that its post-handoff key was both fresh and
  processed to terminal completion. Shortcut conflicts, IME composition, and
  production tab integration remain open;
- the macOS tab mode performs two reader→alternate-tab→reader round trips. Each
  switch hides and destroys the current native child, renders an Iced-only
  alternate tab with no reader placeholder, restores the reader, obtains fresh
  placeholder bounds, recreates and size-checks a new child generation, and
  rejects stale-generation synchronization, hide, input, and replacement
  callbacks. Each of the three reader activations reports the same canonical
  chapter path and `#proof-anchor` logical location before completing a fresh
  child-to-parent keyboard handoff. This proves the harness lifecycle and
  fragment restoration sequence, not integration with Shōsai's production tab
  model or arbitrary character-offset restoration;
- a macOS System Events accessibility snapshot on the 2026-08-19 host found
  exactly one `AXWebArea` and the harness-owned `AXTextField` labeled
  `EPUB proof input` inside the child WebKit tree. The same window exposed its
  native title-bar controls but did not expose the Iced `Focus webview` button
  or any other Iced application control. This is a Gate 0 blocker: WebKit's
  subtree is not enough when the surrounding reader controls are absent. The
  `SHOSAI_WRY_SPIKE_ACCESSIBILITY_PROOF` mode codifies the expected child,
  parent, removal, replacement, generation, and focus sequence through a
  System Events query. With Accessibility permission enabled, the full mode
  confirmed the initial input received accessibility focus, the WebKit web area
  and input both disappeared after teardown, and exactly one fresh web area and
  input returned in generation 3 with input focus. It then exited nonzero
  because the Iced control was absent in every snapshot. Running the mode
  requires the invoking application to have macOS Accessibility permission;
  that permission is an observation prerequisite, not a product requirement;
- ordinary EPUB content JavaScript is disabled, navigation is allowlisted to the book
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

The visibility and scale-bound updates alone prove only that Wry's methods
returned `Ok`; queried scale factors and reported child sizes prove only the
observed window scale and logical geometry. The visual-restoration proof now
establishes matching backing-pixel placement across one hide/recreate cycle on
one rotated 2× arrangement, while the visual observation proves the
uncoordinated z-order failure. It does not establish the remaining display
matrix. Wry's macOS
implementation does not expose AppKit's boolean first-responder result. The
input and tab proofs now supplement that method return with AppKit
first-responder identity, generation-bound IPC, and fresh keyboard events on
both sides of three handoffs across two destroy/recreate cycles. They do not
prove IME routing, shortcut conflicts, production-tab integration, arbitrary
character-offset restoration, or that the restored visual result matches Iced
composition. The scale proof exercises one
real 2→1 display transition, but does not establish correct physical-pixel
rendering across all display arrangements. Clipping, production tabs, IME,
screen-reader interaction, and a viable Iced accessibility tree remain open.
Ordinary close cleanup is
exercised separately on macOS: with Iced's automatic close exit disabled, UI
automation clicked the native close button and the handler recorded that it
dropped the live child before explicitly closing the parent.

On Linux x86_64, the harness compiles against GTK 3.24.51 and WebKitGTK 4.1
(2.50.6) in the Nix development shell. Under Xvfb/X11, the same automated
measured-bounds resize/teardown proof passes and the hostile-content proof
serves the expected page while recording zero book-initiated network
connections. An interactive X11 run also passes the host-owned reader proof for
theme and font injection, fragment navigation, logical location restoration,
search highlighting, and continuous/paginated layout. The harness installs
Wry's documented winit X11 error hook for
the benign WebKit `GLXBadWindow` error 170 and accepts `BadWindow` only after
the one-shot harness explicitly begins teardown, when GTK can destroy the XIM
child before winit's cleanup operations; without those cases, the lifecycle
runs panic during resize or teardown.

The Linux input mode now accepts the same host-owned fixture and state machine
as macOS. It retains early DOM-focus, keydown, exact-input, and confirmed-blur
evidence until the asynchronous Wry focus callback completes. The trusted
fixture synchronously blurs its input when the exact token arrives, verifies
that `document.activeElement` changed, and reports positive blur evidence before
the host may return focus to Iced. The host then waits for queued child events
and checks the X input-focus window against Iced's raw Xlib parent. On the live
XWayland session, Wry selected that parent XID without the direct Xlib fallback;
under Xvfb it did not, so the harness set and synchronously rechecked the Iced
XID directly. In both environments, an untargeted synthetic post-handoff key
did not produce an Iced keyboard event. An XI2 root monitor observed the XTest
raw event, but a separate X11 client selecting core key events on the verified
parent received nothing. A core key event sent directly to that same parent was
received by Iced and completed the proof without pointer activation. This
separates XTest delivery from Iced routing: winit handles a key delivered to the
parent, while the untargeted synthetic control does not establish where a
physical key would be delivered. The initial Xvfb control produced an Iced key
only after an explicit pointer click in the Iced-only header. The harness
observes mouse/touch presses throughout parent handoff and rejects a subsequent
key as pointer-assisted; rerunning that control exits nonzero rather than
printing a successful handoff. This proves child focus and exact text entry,
closes two focus-evidence ordering races, and shows that merely returning `Ok`
or selecting the top-level XID is insufficient evidence of seamless Linux
child-to-parent physical-key routing.
These Linux runs therefore prove X11 child lifecycle, resource policy, and
child keyboard input. They also prove parent routing for a directly addressed
core key, but not physical-key focus restoration, shortcuts, IME, accessibility,
visual fidelity, hardware scaling, Linux arm64, or native Wayland behavior.

The Linux clipboard mode enables Wry's clipboard setting only for a host-owned
fixture and verifies exact tokens in both directions. Under Xvfb, Iced writes
`shosai-parent-clipboard`, reads it back through its clipboard backend, and the
WebKit child pastes the exact token. The child then copies
`shosai-child-clipboard`; a separate GTK process reads that exact token while
the harness continues pumping GTK. However, Iced's own read of the child-owned
clipboard returns no text after its synchronous selection conversion times out,
and the proof exits nonzero with the unexpected `None` result. Iced performs
that conversion on the UI thread, while the WebKitGTK selection owner in the
same process needs that thread's GTK loop to answer. The external-reader control
and the positive opposite direction separate valid WebKit copy ownership from
this same-process event-loop deadlock. Standard bidirectional clipboard
interoperability is therefore blocked without a custom asynchronous GTK
clipboard bridge or another integration change; the failing proof intentionally
records that Gate 0 result.

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

A Wry-only implementation does not satisfy that boundary because it has no
child-view path in Shōsai's Wayland host and would add an unbundled WebKitGTK
runtime to Linux. Silently disabling EPUB rendering on a shipped session type
is not acceptable, and maintaining a second native fallback would retain most
of the native implementation cost while adding webview integration complexity.

Authoritative implementation references:

- [Wry `WebViewBuilder`](https://docs.rs/wry/0.56.1/wry/struct.WebViewBuilder.html)
- [Wry platform considerations](https://docs.rs/wry/0.56.1/wry/#platform-considerations)
- [Iced `window::run`](https://docs.rs/iced/0.14.0/iced/window/fn.run.html)

## Comparison matrix

These are qualitative engineering assessments rather than synthetic numeric
scores. Equivalent rendering measurements remain useful for implementation
quality, but they cannot overcome Wry's failure to support a shipped session
type. Gate 0 therefore rejects Wry at the support boundary instead of spending
more work proving fidelity for a route that cannot ship everywhere required.

| Criterion                  | Wry route                                                                                                     | Native route                                                    | Evidence still needed                                  |
|----------------------------|---------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------|--------------------------------------------------------|
| CSS/table/MathML fidelity  | Promising on macOS system WebKit                                                                              | Production cascade, CSS resources, and bounded font admission are integrated; shaping, block-box, normalized Grid table, and bounded MathML-subset prototypes pass semantic assertions; CSS inline/table algorithms, production font rendering/math integration, and CJK/emoji font coverage remain absent | Combined rendered fixture on every target              |
| Sandbox and offline policy | macOS and Linux/X11 hostile-content proofs record zero network connections; deny handlers configured; CSP/navigation tested | Shared archive/resource admission bounds actual ZIP output and XML/font/image inputs before native presentation | Backend decode allocation enforcement and external-link policy |
| Iced integration           | Measured bounds, resize, focus routing and visibility method returns, observed replacement size, one 2→1 display-scale transition, two Iced tab-state destroy/recreate cycles with repeated input handoffs, and ordinary-close teardown proven on macOS; measured bounds, resize, lifecycle teardown, child focus, exact text input, and directly addressed parent key routing proven on Linux/X11, but physical-key handoff remains unproven and child-to-Iced clipboard reads deadlock without a custom bridge; still outside widget composition | Natural widget composition                                      | Linux physical-key handoff, clipboard bridge decision, physical-pixel correctness, clipping, production tabs, IME, other targets |
| Reader-feature integration | Host-owned Linux/X11 proof applies theme/font size, internal fragment navigation, search highlighting, stable path/fragment/text-offset restoration, and continuous/paginated CSS modes | Existing production features are not connected to the test-only native prototypes | Multi-chapter sample integration and other targets     |
| Accessibility/selection    | WebKit exposes the proof web area and labeled input on macOS, but the surrounding Iced controls are absent from the same accessibility tree; selection is untested | Shaped clusters retain logical source ranges; selection and accessibility are not modeled | Resolve the Iced blocker, then screen-reader, hit-testing, and selection tests |
| Portability                | macOS and x86_64 X11 paths proven; Wayland blocker and platform runtimes differ                                | Existing Iced targets                                           | Windows, Linux arm64, interactive X11, native Wayland  |
| Warm page-turn latency     | Unknown                                                                                                       | Release p50 0.34–2.81 ms, p95 1.20–6.31 ms on the baseline host | Equivalent Wry and cross-platform measurements         |
| Packaging cost             | WebKitGTK added on Linux                                                                                      | `fontdb`, Wuff, Flate2, and Brotli are pure-Rust production dependencies for bounded admission; `cosmic-text` is already present through Iced; test-only Taffy is not selected for production; no direct native MathML dependency was identified | Remaining dependency size; package smoke tests         |
| Maintenance cost           | Browser integration and platform variance                                                                     | Selector/cascade, shaping, block-leaf measurement, explicit table-grid lowering, bounded font admission, and a narrow MathML subset are feasible, but CSS inline/table compatibility plus production font/math policy remain substantial | Native compatibility and accessibility ownership      |

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

Production parsing now retains tables as explicit caption, row-group, row, and
cell nodes rather than flattening their descendants into paragraphs. Header
roles, `scope`, `headers`, `rowspan`, `colspan`, styled links, nested image
references, source block boundaries, and source-order searchable text survive
in the shared chapter presentation. Numeric spans saturate at the HTML semantic
limits (`rowspan` 65,534 and `colspan` 1,000), and rejected image references
retain alt text without entering the canonical resource model. The app consumes
this model through a readable row/cell fallback. Tables wider than the reader
surface use bounded horizontal overflow rather than compressing or discarding
cells. Paginated tables group complete row-span bands into one scroll surface
per actual page fragment and keep the original text offsets. Pagination and
rendering share cell-padding and row/child-spacing geometry; a band taller than
one page remains intact rather than splitting cell content. Reader links use
theme-specific contrast-safe colors through both rich and embedded-font text;
header cells use a contrast-safe theme surface. Nested table links and images
continue through the shared link dispatch and book-local image cache paths.
The test-only explicit Grid remains evidence for the next production step, not
the current layout engine. Full grid placement remains open. Native table and
header accessibility exposure is also open because the Iced 0.14 API available
to this repository provides no accessibility-tree/AccessKit integration point;
implementing honest screen-reader roles therefore requires an upstream
capability or framework upgrade.

## Native EPUB font admission and renderer boundary

The production EPUB document now admits author-supplied fonts after canonical
stylesheet resolution. It parses decoded CSS family aliases, ordered sources,
supported style categories, numeric weight ranges, and supported format hints;
rejects local, foreign, data, query-bearing, escaping, unsupported-format, and
unsupported-technology sources; and applies deterministic source fallback.
TrueType (including Apple `true`) and CFF OpenType sfnt bytes are admitted
directly. WOFF and WOFF2 pass table-directory and decoded-output preflight,
then use output-bounded Wuff callbacks backed by Flate2 and Brotli. Signature,
table-count, family name/list byte, source-reference byte, per-face decoded-byte,
face-count, and aggregate decoded-byte limits apply before a face enters a private
`fontdb::Database` owned by `EpubDoc`. Zero font maxima act as deny-all
boundaries without preventing font-free books from opening.

The CSS family is intentionally an author alias and need not match the face's
internal family.  Computed styles retain ordered named families; native
presentation chooses the first alias admitted for that chapter and preserves
the renderer's existing normal/bold and normal/italic requests for eventual
face matching or synthetic fallback.  Numeric intermediate weights and the
italic/oblique distinction remain M2b presentation semantics; M2a retains
descriptor weight ranges and style categories on admitted faces but does not
retain oblique angles/ranges or claim to retain descriptor metadata in
`TextSpan`. Tests cover all four formats,
missing/corrupt/mismatched and oversized inputs, independent descriptor/source/
admitted-face/family limits, decoded aliases and Unicode case folding, CSS
last-declaration and media-list behavior, bounded fallback diagnostics, chapter
scope, descriptor deduplication, two live books carrying distinct bytes under
the same alias, and releasing one book's binary source without disturbing the
other. The old test-only loading adapter was removed after this production
admission path superseded its evidence.

Iced 0.14 still cannot own these fonts safely: it loads font bytes into a
process-global renderer database, requires `&'static str` for named families,
and exposes no unload operation.  The production native path therefore keeps a
private cosmic-text font system and Swash scaler in each `EpubFontBook`, but
rasterizes glyph images through the uncached API so bitmap variants cannot
accumulate for the lifetime of an open book. Each
Unicode-caseless CSS alias maps to a collision-checked synthetic family that is
visible only in that private database, preventing installed fonts or another
open book from capturing the alias. System faces remain available solely for
missing-glyph and non-embedded-run fallback.

The core shapes rich runs with advanced bidi shaping and word-or-glyph wrapping,
applies the requested base direction independently to every bidi paragraph,
retains contiguous Unicode-scalar line partitions and link rectangles, and can
either measure or produce bounded transparent RGBA line images. Italic matching
prefers an admitted italic face, then a real oblique face, then synthesizes from
normal; a static face whose admitted weight range excludes bold receives a
bounded one-pixel raster emboldening. Native requests stop at 65,536 Unicode
scalars and 4,096 bidi paragraphs. Pagination shapes at most 4,096 scalars per
chunk and adapts later windows to the preceding page fragment instead of
repeatedly shaping an entire remaining suffix. A cumulative per-paragraph work
budget falls back transactionally to heuristic pagination on exhaustion. The app uses the same
measurements for pagination and remeasures every selected page fragment in the
exact context that it renders, avoiding contextual-script and wrap changes
between a full paragraph and its page slices. Search highlights are painted by
logical scalar intersection before glyph rasterization.

An Iced widget measures eagerly but rasterizes only after viewport intersection.
Its tree cache is keyed by the per-book identity and the complete request; owned
image handles and their pixel permit disappear when that tree or book is
replaced. A shared per-book 16-million-pixel retained-raster budget prevents a
continuous document from multiplying the per-call ceiling. Successful native
measurement owns widget height so rendered geometry matches pagination. If
native shaping fails, the widget uses Iced's measured system layout; if late
raster admission fails, it draws each native line as nonwrapping system text in
the already paginated line bounds rather than clipping a differently wrapped
paragraph. No embedded bytes, aliases, or shaped font IDs enter Iced's global
font system.

These are byte-stream and retained-output limits, not a total allocator or CPU
ceiling.  Brotli and transformed-glyph decoding can allocate scratch space;
Wuff exposes opaque decode failures; and hostile-font fuzzing or process
isolation remains release hardening rather than a guarantee of this boundary.

## Native MathML geometry

Production chapter parsing now retains direct MathML expressions as a bounded,
renderer-independent semantic model rather than flattening them irreversibly.
Admission is limited to 64 nodes, 16 levels, and 1,024 bytes of visible text;
supported rows, tokens, fractions, roots, scripts, fences, matrices, and
semantics retain structure. Unsupported but bounded markup keeps readable
source-order fallback, annotations do not leak into visible/search text, and an
over-budget subtree becomes a fixed omission label. Search, pagination, and the
app fallback consume that same bounded fallback.

The application now lowers the retained model—not the source XML—into bounded
native geometry for rows, tokens, fractions, roots, scripts, fences, and
matrices. Direct display math remains an atomic block. Inline MathML identity is
retained independently of native-layout success. An expression becomes an
atomic wrapping-row item only when the same admission used by painting succeeds
for its direction, alignment, glyphs, effective container width, and page
height; otherwise its readable fallback remains splittable text. This admission
also applies inside headings, captions, lists, indented paragraphs, and padded
table cells. Explicit display math nested in a paragraph is promoted to a block
between the surrounding text fragments even when only its fallback is
supported, and an enclosing link remains attached to the promoted block. One
shared layout owns both pagination height and Iced painting, uses reader font
scaling, and paints text and rules with the active reader theme's contrast-safe
text color. The bundled OFL-licensed Inter font makes
measurement and painting deterministic; release archives, installers, and Nix
packages carry its required license notice. Expressions that exceed the
available page width or height, contain an uncovered glyph, or have no supported
expression model retain the readable text path. Search highlights paint the
native box with the active theme highlight instead of changing its paginated
geometry. Search and source offsets always remain based on the original bounded
fallback. Admitted inline expressions remain indivisible during pagination;
their native height and wrapped-line clearance are reserved in addition to
fallback text flow. Right-to-left and justified paragraphs deliberately retain
readable linear fallback until the native flow can preserve full paragraph-level
bidi and justification semantics. Unit tests cover retained link dispatch but do
not synthesize a platform pointer event; repeatable activation in packaged native
apps remains release-validation evidence.

A redistribution-safe XHTML fixture extends the earlier structural fraction and
mixed Latin/Arabic/Japanese evidence with inline and display math, fractions,
square and indexed roots, subscript/superscript operators, a two-by-two matrix,
presentation markup with a TeX annotation, a structurally invalid fraction, and
an unsupported `menclose`. The earlier test-only XML adapter established the
layout formulas; production geometry now consumes the admitted semantic model
directly and uses `cosmic-text` to emit positioned text and horizontal-rule
primitives. Semantic tests prove that:

- supported inline/display expressions produce finite positive width, height,
  baseline, and in-bounds primitive geometry, including compound roots and
  fraction scripts; inline fractions align their rule to the box baseline;
- fractions emit a rule, roots emit overbars, scripts use reduced text, and
  matrix cells retain two-dimensional placement;
- invalid or unsupported constructs fail explicitly while preserving readable
  source-order text fallback; split token text is retained while nested and
  multiline tokens are rejected, and `semantics` requires one presentation
  child followed only by annotations;
- one bounded subtree preflight counts rows, cells, annotations, and
  annotation descendants; enforces the MathML namespace except beneath
  `annotation-xml`; and rejects more than 64 elements, 16 levels, or 1,024 bytes
  of aggregate visible token/fence text before creating fonts or math boxes; and
- the fixture's Latin and Arabic text shapes with nonzero glyphs and RTL levels,
  while Japanese still produces a missing glyph, keeping the known CJK font
  coverage gap visible rather than claiming legibility.

This is a bounded native subset, not standards-conforming MathML rendering. The fixed
heuristics do not read OpenType MATH tables, operator dictionaries, or MathML
style attributes; assemble stretchy glyphs; perform math line breaking; connect
to full computed MathML styling, selection, or accessibility; or bound the initial XML parse
independently of EPUB resource limits. Token shaping is deliberately single-line
and requires every source byte to map to a non-missing glyph. Unsupported cases
therefore use readable fallback rather than approximating standards coverage.

Dependency inspection found no maintained permissively licensed Rust library
that accepts existing Presentation MathML and emits native geometry. `mathml`
0.4.4 and `mathml-rs` 0.1.2 are inactive MIT/Apache-2.0 Content MathML parsers
without typographic layout. `alemat` 0.8.0 is an Apache-2.0 MathML builder and
serializer, not an input parser or layout engine. `katex-rs` 0.2.4 is active and
MIT-licensed and contains substantial math layout, but accepts TeX and emits a
KaTeX HTML/CSS/MathML/SVG model rather than consuming EPUB MathML or producing a
renderer-neutral native glyph scene. Adapting it would still require a MathML
front end and native font/scene backend. No candidate was added merely to wrap
the wrong input or output boundary; selecting the native route therefore means
owning or funding a substantial MathML integration rather than filling this gap
with a current dependency.

## Native performance baseline

The dated
[2026-08-17 EPUB page-turn benchmark](../../benchmarks/epub-page-turn/2026-08-17/)
records the synthetic app-action-to-compositor-present protocol, reproducible
workloads, host details, budgets, and complete native baseline. All measured
paths met their initial budgets; large-text relayout was the dominant native
cost.

## Native implementation follow-up

1. Extend the native component evidence with inline-tree construction, a fuller
   table compatibility boundary, production font shaping/rasterization,
   selection/accessibility, pagination, and MathML, then render the combined
   fixture. Treat every test-only prototype as evidence, not a production
   implementation.
2. Preserve the shared resource, hostile-input, stable-location, and reader
   feature contracts independently of presentation code.
3. Run the release performance and packaging protocols on macOS arm64, Linux
   x86_64/arm64 under X11 and Wayland, and backend-independent Windows CI as
   native milestones enter production.
4. Keep unsupported CSS and MathML behavior explicit and readable rather than
   silently approximating browser behavior.

## Decision

Select the expanded native renderer for production EPUB work and close Gate 0.
This decision prioritizes the shipped platform boundary and one composable Iced
application tree over browser-level fidelity:

- native rendering works within the existing macOS, Linux X11, Linux Wayland,
  and Windows build architecture without adding a platform web runtime;
- Iced composition avoids native-child clipping, overlay, tab-lifecycle, focus,
  clipboard, and split accessibility-tree problems;
- EPUB bytes remain behind one Rust resource-policy boundary rather than being
  served to several platform engines with different behavior;
- the existing production renderer and the bounded native cascade, shaping,
  block, table, font, and MathML prototypes provide an incremental path, even
  though substantial fidelity and accessibility work remains.

### Rejected alternatives

- **Wry-only:** rejected because native Wayland child embedding is unavailable,
  Linux packaging requires WebKitGTK, Linux clipboard interoperability is
  blocked without a custom bridge, and macOS does not expose one complete Iced
  plus WebKit accessibility tree.
- **Wry with a native fallback:** rejected because it requires both renderer
  stacks, duplicate behavioral testing, and platform-dependent reading output
  while retaining nearly all native implementation and maintenance cost.
- **Defer the decision:** rejected because the hard portability failure is
  sufficient to choose an architecture; additional Wry fidelity evidence would
  not make Wry-only shippable on the current support boundary.

### Consequences and rollback

Native does not imply full browser compatibility. Shōsai owns a documented CSS
subset, table behavior, EPUB-local font policy, bounded MathML support and
fallback, selection/accessibility mapping, pagination, and stable locations.
Milestones must land behind semantic fixtures and keep the existing readable
fallback until each replacement path is proven.

Reconsider a webview backend only through a new ADR if the host architecture can
embed one composably on every shipped session type, Linux distribution includes
an accepted runtime strategy, focus/clipboard/accessibility blockers have
platform proofs, and measured maintenance or fidelity shows that the bounded
native route cannot meet agreed acceptance criteria. The optional Wry spike may
be removed if it stops providing useful comparison evidence; it must not
silently become a production fallback.
