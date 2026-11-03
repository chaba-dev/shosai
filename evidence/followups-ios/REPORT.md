# Follow-ups on iOS at verify-all 0c19676: device verification

Build under test: `claude/project-thread-r96hxq-verify-all` at 0c19676 (PDF tap
turns without the double-tap wait, the old PDF line kept until the curl turns
it, a still stage and shadow under a curl, the panel scrim below the toolbar,
the quiet PDF place line on tablets, and EPUB page numbers through the book).
Run on 2026-11-02 on Darwin's devices attached to the Mac mini:

| Device | Model | iOS | Logical size | Refresh | Locale |
| --- | --- | --- | --- | --- | --- |
| iPhone 15 Pro Max | iPhone16,2 | 27.2 | 430 × 932 pt @3x, portrait | 120 Hz | Japanese (`ja`) |
| iPad Air 5 | iPad13,17 | 27.2 | 1180 × 820 pt @2x, landscape, two pages | 60 Hz | English |

Also in this round: the macOS golden for PR #276
(`test/goldens/macos/reader-pdf-1280.png`) was regenerated, checked by eye (PDF
page with `page 1 of 3` under it), passed the visual tests without
`--update-goldens`, and was pushed to
`claude/project-thread-r96hxq-pdf-place-docs` as c56e1d3.

## Summary

| # | Check | iPhone (ja) | iPad |
| --- | --- | --- | --- |
| 1 | PDF tap turn starts promptly (< ~200 ms) | **Pass**: curl on screen 17–23 ms after the finger lifts (median 18), leaf moving at 33–59 ms (median 37) | **Pass**: curl 18–32 ms (median 31), leaf moving at 80–98 ms (median 86) |
| 1 | PDF place line changes with the curl, not before | **Pass**: the old line stays, then cross-fades 3 → 4 as the leaf turns and reads 4 when it lands (~380–420 ms) | **Pass**: the old line `pages 4–5` stays for the whole curl and reads `6–7` as it lands (~415 ms); no visible gradual fade |
| 2 | Backdrop steady during a curl | **Pass**: 0 changed pixels outside the page in tap and held curls; no seam above the place line | **Pass**: 0 changed pixels outside the page and shadow (PDF and EPUB) |
| 2 | Page shadow steady during a curl | n/a (full-bleed PDF page, no shadow) | **Fail on PDF**: the spread's drop shadow loses its left side and soft lower-left corner while a curl is on screen (held and tap), and comes back when it ends. **Pass on EPUB**: 0 changed pixels in the shadow ring |
| 3 | Aa panel scrim, no uncovered strip under the status bar | **Pass (no strip)**, but see note: the scrim starts at the toolbar's bottom (y 115 = 59 status bar + 56 toolbar); status bar and toolbar are evenly undimmed, it does not reach the top edge | **Pass (no strip)**: the panel is a popover with a clear scrim starting under the toolbar (y 88 = 32 + 56); nothing dimmed |
| 4 | Quiet PDF shows its place line like the phone | n/a (phone already did) | **Pass**: `pages 4–5 of 15` under the spread with the chrome hidden |
| 5 | EPUB: cover alone is page 1, next spread pages 2 and 3 | Cover `1ページ`, then `2ページ`, `3ページ` … | **Pass**: cover alone `page 1`; next spread `page 2 · page 3`; then 4–5, 6–7, 8–9 |
| 5 | EPUB: late chapter from Contents matches paging | **Pass**: Contents → CHAPTER L → `479ページ`; paging 450 pages from Chapter I lands on the same page, `479ページ` | **Pass**: Contents → CHAPTER L → `page 535 · page 536`; paging 253 spreads from Chapter I lands on the same spread, same numbers |
| 5 | EPUB: text size up and back keeps the number | **Fail**: `479ページ` → larger `594ページ` → back `484ページ`, on a page that starts *earlier* in the text than 479 | **Fail**: `page 535 · 536` → larger `686 · 687` → back `544 · 545` (+9) at nearly the same place; also `93 · 94` → `95 · 96` (+2) at the identical place. Neither settles after 30 s |

No exceptions were logged in any run.

## Findings in detail

### F1. iPad PDF: the page shadow changes during a curl (check 2, fail)

On the iPad two-page PDF, while a curl is on screen the drop shadow around the
spread is not the same as at rest: the shadow on the left side of the spread
disappears and the soft lower-left corner turns into a hard edge, so the
shadow under the spread looks like a flat band that starts at the page edge.
It returns to normal as soon as the curl ends. This is in the real device
screenshots, not only in-app captures:
`analysis/ipad-pdf-shadow-device.png` (top: quiet, bottom: a held curl) and
`analysis/ipad-pdf-shadow.png` (in-app frames: before, 210 ms, 310 ms, 394 ms
and 427 ms into a tap turn). The backdrop colour itself does not change: 0
pixels differ outside the page and its shadow in every curl frame. The EPUB
spread's shadow on the iPad is unchanged during curls (0 pixels differ).

### F2. EPUB text size up and back changes the page number (check 5, fail)

Found three times on the iPad and once on the iPhone; the number does not
come back after 10 s or 30 s.

| Device | Before | Text larger | Text back | Place before → after (unit:offset) |
| --- | --- | --- | --- | --- |
| iPad | `page 535 · page 536` | `page 686 · page 687` | `page 544 · page 545` | 5:82300 → 5:82215 |
| iPad | `page 93 · page 94` | `page 116 · page 117` | `page 95 · page 96` | same place, 82593 |
| iPhone | `479ページ` | `594ページ` | `484ページ` | 5:82342 → 5:81305 |

`page 535 · 536` and `479ページ` are confirmed correct by paging from Chapter I
(check 5, second row). After the round trip the iPhone page starts about 1,000
characters *earlier* than the 479 page, yet reads 484. The book's place is
kept (within a page). Only the number is off. Screenshots:
`ipad/run5-epub-text-larger.jpg`, `ipad/run5-epub-text-back.jpg`,
`iphone/run2-epub-text-larger.jpg`, `iphone/run2-epub-text-back.jpg`.
Early in the book the iPhone round trip kept `6ページ` (`iphone-run1.log.txt`).

### F3. Aa panel scrim: no strip, but it stops under the toolbar (check 3)

There is no partly dimmed strip any more. With the Aa sheet open the status
bar and the toolbar are evenly bright, and the page below is dimmed
(`iphone/run1-04-pdf-aa-panel.jpg`, `iphone/run1-07-epub-aa-panel.jpg`). This is
what 2de472f says it does ("the scrim dims the page … and leaves the chrome
alone"). The check list asked for a scrim that covers the whole screen to the
top edge; the build does not do that by design. If the top edge is what's
wanted, it is a spec change, not a regression. On the iPad the Aa panel is a
popover and its scrim is clear, so nothing is dimmed.

### Minor notes

- **PDF place line during a curl:** while a curl is on screen the line is
  drawn from the snapshot, which is slightly jagged on the iPhone (3x);
  compare `analysis/iphone-pdf-line-device.png`. On the iPad it looks the same
  as at rest (`analysis/ipad-pdf-line-device.png`). The zoomed in-app frames
  are `analysis/iphone-pdf-line-zoom.png` (cross-fades 3 → 4) and
  `analysis/ipad-pdf-line-zoom.png` (stays `4–5`, then `6–7`).
- **Running head after a Contents jump:** the page reached from Contents shows
  the head `"The spiteful old ladies." CHAPTER L.`; the identical page reached
  by paging shows `CHAPTER XLIX.` (both screenshots in `ipad/run5-…` and
  `iphone/run2-…`). The page starts in chapter XLIX in this Gutenberg file,
  so the paging head is the consistent one.
- **iPhone jump screenshot:** the `第1章に戻る` (Back to chapter 1) capsule
  covers the folio after a Contents jump, so the page number is not visible
  until it is dismissed (`iphone/run2-04-epub-jumped-chapter-50.jpg`).
- **Contents choice:** picking a chapter opens a preview with Close and Go to
  rather than jumping; the harness taps Go to. Noted only because it
  differs from the check's wording.
- **iPad contents spread:** the spread after the cover is the book's own table
  of contents, all links; a tap in the outer quarter at mid-height lands on a
  link and does not turn (by design, as on 11-02). The EPUB runs tap just
  below the text.
- Frame timings during PDF tap turns: iPad 322 frames, build p95 0.88 ms,
  raster p95 1.35 ms, none over the 16.7 ms budget; iPhone 545 frames at
  120 Hz, build p95 0.44 ms, raster p95 0.56 ms, none over 8.3 ms.

## How it was run

The same method as the 11-02 run (`evidence/quiet-page-main-ios`), with a new
harness for these checks: `followups_ios_test.dart.txt`.

- An uncommitted integration test drove the production `ShosaiApp` with touch
  taps and drags through `WidgetTester`, with `framePolicy = fullyLive`. Its
  data directory was a new temporary directory, so the app's real library and
  settings were never read or written. Pride and Prejudice (Gutenberg 1342,
  EPUB 3 with images, images downscaled to keep the app small) and *Attention
  Is All You Need* (15-page PDF) were bundled as temporary assets and imported
  into that library. The iPhone ran with `locale: ja`, the iPad with `en`.
- Built as a **profile** app with the official Flutter 3.41.5 SDK in a clean
  environment (`flutter build ios --profile -t integration_test/followups_ios_test.dart`),
  installed over the app with `devicectl device install app` and launched with
  `devicectl device process launch --console`. Throwaway-worktree build
  workarounds as on 11-02: deployment target 15.0, `DEVELOPMENT_TEAM` set.
- At each checkpoint the harness printed `SHOT <label>` and held still; a
  watcher took a real device screenshot with `pymobiledevice3 developer dvt
  screenshot`.
- **Tap-turn latency (check 1):** ten touch taps alternating 85 % / 15 % of
  the tap area. A stopwatch starts as the finger lifts; each frame records
  whether `reader-page-curl` is drawn, the curl painter's progress, whether
  its incoming page is captured, and the folio widget's text. "Curl first" is
  the first frame with the curl; "leaf moves" is the first with progress > 0.
  It does not include the touch screen's own input latency before the event
  reaches Flutter.
- **Recordings:** `devicectl device capture screen-record` is not supported
  on these devices (CoreDevice reports the Screen Recording capability
  missing), so the recordings are **in-app frame captures**: every frame of a
  tap turn or held drag was captured with `RepaintBoundary.toImageSync` at 1x,
  encoded after the turn, and assembled into MP4 at the frames' real
  timestamps (`recordings/mkvideo.sh.txt`). Each tap turn has a real-time and a
  4x-slow version.
- **Steady stage (check 2):** `analysis/analyze.py.txt` compares every curl
  frame with the frame before the tap: pixels differing by more than 24/255
  outside the page and its 28 pt shadow margin, inside that shadow ring, and
  the place line against the old and new lines.
- **EPUB numbers (check 5):** Contents → `CHAPTER L.` → Go to; read the folio
  once numbered. Then page animations off, Contents → `Chapter I.` → Go to,
  and tap forward (just below the text) until the jumped-to page is on screen;
  compare folios and places. Places are keyed by spine unit and canonical
  offset. Then Aa → text larger → read; Aa → text smaller → read, and read
  again after 10 s and 30 s.
- Runs: iPad run 1 (PDF and EPUB opening), run 3 (EPUB opening, Aa, curls,
  first text-size result), run 5 (jump, paging, text size); iPhone run 1 (all
  but paging) and run 2 (jump, paging, text size). Runs 2 and 4 on the iPad
  and part of iPhone run 1 were spoiled by harness bugs (links under the tap,
  the Contents preview, per-unit offsets) and are not used.

## State left on the devices

- Both devices have a normal profile build of 0c19676 (no harness, no test
  books) installed over the app and launched. The app was never deleted.
- **iPhone:** the Library in Japanese, 21 books, as at the start
  (`iphone/00-before-library.jpg`, `iphone/99-after-library.jpg`).
- **iPad:** before the run it showed the home screen. On launch the app
  reopened the last book in its real library, `Physical Public Curl` (a
  synthetic PDF from an earlier session, not this run), showing the new
  `pages 2–3 of 5` place line (`ipad/99-after-app-reopened-last-book.jpg`).
  One tap on Library in the rail goes back; I did not drive the real app to
  do that.
- **Storage:** the iPad had 3 MB free and refused an install. I deleted only
  the folders this harness creates in the app's `tmp/` (`qp-books-*`,
  `qp-data-*`, `qp-frames-*`) on both devices, after copying the frames off.
  Nothing else was deleted; the real library was not touched.
