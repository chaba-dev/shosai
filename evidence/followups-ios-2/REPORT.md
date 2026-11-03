# Follow-ups on iOS, round 2: F2 diagnosis and F1 re-check

Run on 2026-11-02 on the iPad Air 5 (iPad13,17, iPadOS 27.2, 1180 × 820 pt
@2x landscape, two pages, English) attached to the Mac mini. Build:
`debug/epub-numbers-ios` at 6783547, which is `verify-all` df91a4d plus
`SHOSAI-DBG` print lines, as a profile app installed over the app. Round 1 is
in `evidence/followups-ios`.

| Item | Result |
| --- | --- |
| F2: EPUB number after text size up and back | **Reproduced; cause found.** The text size does not come back: 16.0 → 18.0 → **16.2**. The numbers are consistent for each size. Not a numbering bug. |
| F1: iPad two-page PDF shadow under a curl | **Held curl: fixed.** Left side and soft corners stay as at rest. **Tap turn: mostly fixed.** Left side holds, but the shadow under the spread darkens steadily as the leaf turns (luma 165 → 127), then snaps back when it lands. |

## F2: what the log shows

Full log: `F2-log.txt` (every `SHOSAI-DBG` line from just before the text
size change to the end, with the numbers and places on screen). Raw device
log: `logs/ipad-syslog.log.txt`.

| Step | Font size (layout key) | Folios | Place (unit:start) | Pages before this one (`before=`) |
| --- | --- | --- | --- | --- |
| Contents → CHAPTER L → Go to | f16.0, h626 | `page 535 · page 536` | 5:82300 | 462 |
| Aa → larger | f18.0, h626 | `page 687 · page 688` | 5:83169 | 592 |
| Aa → smaller | **f16.2**, h626 | `page 544 · page 545` | 5:82215 | 470 |
| Close Aa, chrome hidden 10 s | f16.2 | `page 544 · page 545` (all 10 s) | 5:82215 | 470 |

- The height never changes (h626 throughout, `viewport=626`). No
  `layoutChanged` fires during the sequence, and the chrome showing and hiding
  does not change the layout.
- "Smaller" produces a new layout key, f16.2, and a third set of page counts
  (`entries=[h626.0/f16.0, h626.0/f18.0, h626.0/f16.2]`). The f16.0 count is
  never used again.
- Why: the stored default EPUB text size is 16
  (`packages/shosai_core/lib/src/reading/reader_settings.dart`,
  `epubFontSize = 16`). The Aa stepper (`lib/reader/view_panels.dart`,
  `_ReaderDisplayPanel`) shows sizes as a share of an 18 pt base, rounded to
  10 %: 16 / 18 = 88.9 % shows as "90%". "+" sets 100 % = 18.0; "−" then sets
  90 % = 16.2, not 16.0. The two steps are not inverses unless the size is
  already on the 10 % grid.
- At 16.2 pt the pages are slightly shorter. Chapter L starts on a later page
  (470 pages before it vs 462), so 544–545 is plausibly right for 16.2 pt. I
  did not page from Chapter I at 16.2 to prove it. At 16.0 the jump and paging
  agreed (round 1).
- Round 1's iPhone result (479 → 594 → 484) fits the same cause; I did not
  re-run the iPhone, since the iPad reproduced.

Page area when the chrome shows and hides on the iPad: **it does not move.**
The stage, page, tap area, running heads (y 80), text (y 100–726) and folios
(y 735) have the same rects with the chrome hidden, shown and hidden again.
The toolbar appears at y 32–88, just under the status bar, over the top of
the page, without pushing it. Safe area: top 32 pt (the status bar stays visible on
the iPad), bottom 25 pt; the rail takes x 0–56.

## F1: re-check with df91a4d's fix

- **Held curl**, real device screenshots: `analysis/ipad-pdf-shadow-device-left.png`
  and `analysis/ipad-pdf-shadow-device-right.png` (top: at rest, bottom: a
  curl held at about a third). The left-side shadow and both soft lower
  corners are the same as at rest. Round 1's
  `evidence/followups-ios/analysis/ipad-pdf-shadow-device.png` showed them gone.
- **Tap turn**, in-app frames: `analysis/ipad-pdf-shadow-tap-turn-inapp.png`,
  `analysis/ipad-pdf-tap-turn-forward-4x-slow.mp4`, and the measurements in
  `analysis/ipad-pdf-tap-turn-shadow-luma.txt`.
  - The left edge is constant (luma 206.1 in every frame).
  - Outside the page and its shadow, 0 pixels change.
  - The band just under the spread darkens in step with the curl: 165 at
    rest, 163 at 108 ms, 149 at 209 ms, 137 at 276 ms, 127 at 392 ms. It snaps
    back to 165 when the curl ends (410 ms).
  - That looks like the shadow being drawn twice. Since 92b6a38 the curl
    painter draws the outgoing stage snapshot at full opacity and fades the
    incoming one in over it with opacity = progress; both snapshots contain
    the drop shadow, so it builds up to roughly double darkness at the end of
    the turn.
  - A held curl barely shows it, because its progress stays low.

## How it was run

The harness from round 1, with a round-2 mode (`logs/round2_test.dart.txt`).
It drives the production `ShosaiApp` with touch input in a temporary library
(the real library was never opened), with Pride and Prejudice and *Attention Is
All You Need* bundled as temporary assets. `SHOSAI-DBG` lines are `print()`
calls, which in a profile app go to the device log, so the log was read with
`pymobiledevice3 syslog live --process-name Runner`. The harness's own lines
and `SHOSAI-MARK` markers went to the same log, so the order is exact. Device
screenshots: `pymobiledevice3 developer dvt screenshot` at each `SHOT`.

## State left on the devices

- Both devices have a normal profile build of
  `claude/project-thread-r96hxq-verify-all` at df91a4d (no debug prints, no
  test assets) installed over the app and launched. The app was never
  deleted, and the real libraries were not touched.
- iPhone: on the Library (Japanese, 21 books): `99-iphone-after-library.jpg`.
- iPad: on launch the app reopens the last book in its real library,
  `Physical Public Curl` (from an earlier session), as in round 1
  (`ipad/99-after-app-reopened-last-book.jpg`). Getting it to the Library
  takes one tap on Library in the rail; I did not drive the real app against
  the real library to do it.
- The harness's own `tmp/qp-*` folders were deleted after their frames were
  copied off. Nothing else was removed.
