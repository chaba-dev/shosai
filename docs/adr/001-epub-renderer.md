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
cargo test -p shosai-app --example epub-wry-spike --features epub-wry-spike
```

It currently proves on macOS arm64 that:

- Iced 0.14's public `window::run` callback exposes a parent window handle that
  Wry 0.56.1 can use to build a child `WKWebView`;
- an in-memory `shosai:` custom protocol can render a chapter containing CSS,
  a table with `rowspan`, and presentation MathML;
- the child can be resized with its Iced parent and explicitly focused;
- content JavaScript is disabled, navigation is allowlisted to the book
  protocol, downloads and new windows are denied, and a restrictive CSP is
  attached to protocol responses.

The successful macOS run was visually checked. The security callbacks and CSP
are configured and unit-tested, but the required proof that no remote subresource
request reaches the network is still outstanding. The harness serves the XHTML
bytes as `text/html`; serving the same valid XML as `application/xhtml+xml`
produced a WebKit XML error and needs investigation before the spike can claim
EPUB MIME-equivalent behavior.

## Integration findings

Iced has no supported native-child widget abstraction. A production Wry route
would need an Iced placeholder plus application-owned platform state to:

- report the reader pane's actual visible bounds instead of the spike's fixed
  header/padding geometry;
- synchronize bounds, clipping, visibility, scale factor, focus, IME, overlays,
  tab switches, and teardown;
- keep Wry objects on the UI thread while communicating lifecycle results back
  through Iced messages;
- map DOM locations to stable EPUB chapter/fragment/text anchors.

Native children normally sit above Iced's GPU surface. Menus, search UI,
bookmarks, and dialogs cannot be assumed to overlay or clip the child correctly.
Those behaviors need explicit tests rather than visual inference.

## Platform and packaging findings

| Target | Child-view path | Current finding |
|---|---|---|
| macOS 12+ | Iced raw AppKit handle → child `WKWebView` | Builds and renders with the system WebKit; no extra runtime packaged |
| Windows CI | Iced raw Win32 handle → child WebView2 | API path exists; runtime, accessibility, focus, and CI spike not yet tested |
| Linux X11 | Iced raw Xlib handle → WebKitGTK child | Requires GTK initialization/event pumping and WebKitGTK 4.1; current Nix/release dependencies do not include them |
| Linux Wayland | GTK container via Wry Unix extension | Raw child embedding is unsupported; standard Iced runner exposes no GTK container, making this the main Wry portability blocker |

Wry 0.56.1 is Apache-2.0 OR MIT and uses system engines. A full transitive
license report and notices check remains required. Windows is tested in CI but
is not currently a release artifact, so build support and shipped support must
not be conflated.

Authoritative implementation references:

- [Wry `WebViewBuilder`](https://docs.rs/wry/0.56.1/wry/struct.WebViewBuilder.html)
- [Wry platform considerations](https://docs.rs/wry/0.56.1/wry/#platform-considerations)
- [Iced `window::run`](https://docs.rs/iced/0.14.0/iced/window/fn.run.html)

## Comparison matrix

Scores remain unset until the same fixture and measurement protocol is used.

| Criterion | Wry route | Native route | Evidence still needed |
|---|---|---|---|
| CSS/table/MathML fidelity | Promising on macOS system WebKit | Unknown | Combined fixture on every target |
| Sandbox and offline policy | Handlers/CSP configured, network proof incomplete | Smaller surface, resource policy incomplete | Hostile fixture plus network monitor/proxy |
| Iced integration | Possible but outside widget composition | Natural widget composition | Focus, overlay, clipping, tabs, IME |
| Accessibility/selection | Unknown platform behavior | Not currently modeled | Screen-reader and selection tests |
| Portability | Wayland blocker; platform runtimes differ | Existing Iced targets | macOS, Windows, X11, Wayland spikes |
| Warm page-turn latency | Unknown | Release p50 0.34–2.81 ms, p95 1.20–6.31 ms on the baseline host | Equivalent Wry and cross-platform measurements |
| Packaging cost | WebKitGTK added on Linux | Dependency set not selected | Binary/runtime/package smoke tests |
| Maintenance cost | Browser integration and platform variance | CSS/layout implementation scope | Native component/dependency prototype |

## Fixture and measurement matrix

| Fixture/workload | Wry | Native/current | Required assertion |
|---|---|---|---|
| Existing `sample.epub` | Not wired yet | Existing tests pass | Navigation, search, progress unchanged |
| Table (`rowspan`, caption) | Static spike renders on macOS | Not represented faithfully | Structure, overflow, pagination, headers |
| Presentation MathML fraction | Static spike renders on macOS | Not represented faithfully | Inline/display scaling and fallback text |
| WOFF2/TTF/OTF and fallback | Not started | Not started | In-archive only, deterministic fallback |
| RTL and mixed script | Not started | Not started | Order, shaping, selection, navigation |
| Traversal/duplicate paths | Not started | Current resolver is unsafe | Canonical rejection and no aliasing |
| Remote script/image/font/navigation | Policy configured only | No content fetch; external click opens system handler | Zero book-initiated network requests |
| Malformed/oversized input | Not started | Limits incomplete | Bounded failure with diagnostics |
| Warm turn/chapter/relayout latency | Not measured | Native release baseline recorded below; all initial budgets pass | Equivalent Wry and cross-platform runs |

## Native performance baseline

The app contains an opt-in release harness in `app/perf.rs`. It starts timing
when Iced delivers a navigation or font-size action to the application and
finishes when the subscription result for the resulting Iced redraw is
processed. In Iced 0.14's Winit runner, that redraw event is broadcast after
draw and directly before `compositor.present`; its subscription message is
processed after the current event-loop callback. The metric therefore covers
application input dispatch, state/pagination work, Iced layout/draw, and
compositor presentation. It does not include the OS input event before Iced
dispatch, physical display scan-out, or panel response time.

Run the complete protocol with:

```sh
./scripts/benchmark-epub-turns.sh 50
```

The script builds `--release`, generates redistribution-safe large text and
image EPUBs under `target/`, fixes the benchmark viewport at 700×700 (588 px
reader, single page) and 1000×700 (888 px reader, spread), waits 60 frames for
window stabilization, discards five operation warmups, then records 50 samples.
The generated books contain 16 chapters so the same run can select stable
within-chapter and chapter-boundary pairs. Initial budgets are:

| Operation | p50 budget | p95 budget |
|---|---:|---:|
| Warm page turn | ≤ 8 ms | ≤ 16.7 ms |
| Chapter transition | ≤ 16.7 ms | ≤ 33.3 ms |
| Font-size relayout | ≤ 50 ms | ≤ 100 ms |

Baseline host: MacBook Pro Mac16,5, Apple M4 Max, 48 GB, macOS 26.5.2, rustc
1.94.0. Results from 2026-08-17 (milliseconds):

| Fixture | Mode | Operation | p50 | p95 |
|---|---|---|---:|---:|
| `sample.epub` | Single | Chapter transition | 0.581 | 1.618 |
| `sample.epub` | Single | Relayout | 0.432 | 0.662 |
| `sample.epub` | Spread | Chapter transition | 0.684 | 1.699 |
| `sample.epub` | Spread | Relayout | 0.366 | 0.598 |
| Generated large text | Single | Warm page turn | 1.603 | 2.906 |
| Generated large text | Single | Chapter transition | 1.370 | 3.465 |
| Generated large text | Single | Relayout | 18.018 | 20.671 |
| Generated large text | Spread | Warm page turn | 2.813 | 6.306 |
| Generated large text | Spread | Chapter transition | 1.835 | 3.435 |
| Generated large text | Spread | Relayout | 22.485 | 25.588 |
| Generated large image | Single | Warm page turn | 0.337 | 1.196 |
| Generated large image | Single | Chapter transition | 0.587 | 1.683 |
| Generated large image | Single | Relayout | 1.341 | 2.944 |
| Generated large image | Spread | Warm page turn | 0.581 | 1.258 |
| Generated large image | Spread | Chapter transition | 0.846 | 2.204 |
| Generated large image | Spread | Relayout | 1.223 | 2.010 |

The small checked-in fixture has no within-chapter warm pair, so that cell is
intentionally omitted. Large-text relayout remains the dominant native cost but
is within the initial budget. These numbers are a renderer-comparison baseline,
not a universal guarantee; repeat the same protocol on released platforms and
under representative power/display conditions.

## Next spike steps

1. Serve `sample.epub` chapter and manifest resources from bytes through the
   custom protocol using one canonical resolver; record every request and prove
   remote requests are blocked with a network monitor or controlled proxy.
2. Replace fixed child bounds with an identified Iced placeholder and test
   resizing, scale changes, overlays, tabs, focus, IME, and teardown on macOS.
3. Run the same child spike on Windows and Linux/X11. Decide whether lack of a
   viable Wayland host rejects Wry or justifies a documented backend fallback.
4. Build the native computed-style boundary for the same table/font/MathML/RTL
   fixture, inventory maintained permissive selector/layout/math dependencies,
   and estimate unsupported work explicitly.
5. Run the same release performance protocol for Wry and on the other released
   platforms before assigning final comparison scores or choosing a renderer.

## Decision

No renderer selected. Gate 0 remains open.
