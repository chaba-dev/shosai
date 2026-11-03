# Follow-ups on iOS, round 3: F1 and F2 fixes at verify-all fea4478

Run on 2026-11-02 on the iPad Air 5 (iPad13,17, iPadOS 27.2, 1180 × 820 pt
@2x landscape, two pages, English) attached to the Mac mini. Build:
`claude/project-thread-r96hxq-verify-all` at fea4478 (includes fa8bd40, text
size steps back to the exact size, and 138c619, a steady PDF spread shadow
through a tap turn), profile, run through the round-1/2 harness in a temporary
library and installed over the app. Rounds 1 and 2: `evidence/followups-ios`,
`evidence/followups-ios-2`.

| # | Check | Result |
| --- | --- | --- |
| 1 | F2 at CHAPTER L (Contents → Go to), Aa + then Aa − | **Pass**: label 90% → 100% → 90%; folios `page 535 · page 536` → `648 · 649` → `535 · 536`, same place (unit 5, offset 82300), unchanged after 10 s with the chrome hidden |
| 1 | F2 mid-book (120 spreads paged from Chapter I) | **Pass**: label 90% → 100% → 90%; folios `page 271 · page 272` → `326 · 327` → `271 · 272`, same place (unit 3, offset 46694), unchanged after 10 s |
| 2 | F1 tap turn: shadow band under the spread | **Pass**: luma 164.8 at rest, 165.0 at ~210 ms, 165.0 at ~394 ms, 164.8 after; round 2 went 165 → 149 → 127 |
| 2 | F1 held curl: left side and lower corners | **Pass**: same as at rest in device screenshots |
| 3 | PDF tap turn starts promptly | **Pass**: curl on screen 17–34 ms after the finger lifts (median 31), leaf moving at 64–97 ms (median 85); round 1 was 18–32 / 80–98 |
| 3 | Place line changes with the curl | **Pass**: cross-fades `pages 4–5` → `6–7` during the curl (half and half at ~210 ms, mostly new at ~343 ms) and reads `6–7` when it lands |

No exceptions were logged.

## Evidence

- `ipad/ipad-05…08-f2a-*.jpg` and `ipad/ipad-09…12-f2b-*.jpg`: device
  screenshots at the start, with the text larger (panel open, 100 %), back
  (panel open, 90 %) and after 10 s with the chrome hidden.
- `analysis/ipad-pdf-tap-turn-shadow-luma.txt`: per-frame brightness of the
  band under the spread (x 200–560, y 729–740), the left edge and the lower
  right corner for a forward and a back tap turn. Outside the page and its
  shadow, 0 pixels change in any frame. In the shadow ring, up to about
  1,000 scattered pixels (about 1 % of the ring) along the bottom edge of the
  spread (x 95–1144, y 727–758) differ by more than 24/255 during the curl,
  growing from ~100 early in the curl to ~1,000 by ~240 ms. The band's mean
  brightness stays within 0.5 of rest. Round 2 changed by ~20,000 pixels and
  38 levels of brightness. I could not see a difference by eye
  (`analysis/ipad-pdf-shadow-tap-turn-inapp.png`).
- `analysis/ipad-pdf-shadow-device-left.png`, `…-right.png`: device
  screenshots at rest (top) and with a curl held (bottom).
- `analysis/ipad-pdf-shadow-tap-turn-inapp.png`: the lower-left of the spread
  in in-app frames before, 210, 310, 394 and 427 ms into a tap turn.
- `analysis/ipad-pdf-line-zoom.png`: the place line through a forward turn.
- `analysis/ipad-pdf-tap-turn-forward-{realtime,4x-slow}.mp4`: every in-app
  frame of a forward tap turn at its real timing (screen recording is not
  supported on these devices through `devicectl`).
- `logs/ipad-console.log.txt`, `logs/round3_test.dart.txt`: the run log and
  the harness.

## State left on the devices

- Both devices have a normal profile build of fea4478 (no harness, no test
  books) installed over the app and launched. The app was never deleted and
  the real libraries were not touched. The harness's `tmp/qp-*` folders were
  deleted after their frames were copied off.
- iPhone: on the Library (Japanese, 21 books): `99-iphone-after-library.jpg`.
- iPad: on launch the app reopens the last book in its real library,
  `Physical Public Curl`, as in rounds 1 and 2
  (`ipad/99-after-app-reopened-last-book.jpg`). Getting it to the Library
  takes one tap on Library in the rail; I did not drive the real app against
  the real library to do it.
