# Quiet page on Android, main after #262–#266: device verification

- Build: `main` at `42a03fc8` (#262 safe areas and rail, #263 pointer mode and furniture, #264 stable window geometry, #265 quarter zones and idle hide, #266 page curl). `make android-profile`, installed with `adb install -r` over the existing app (lastUpdateTime 2026-11-02 01:05:47). Data and books were kept, and the app is left installed at this build.
- Device: Pixel 5a (`barbet`) on Android 14, 1080×2400 at 420 dpi, gesture navigation.
- Method: the same as the 2026-10-30 run (`evidence/quiet-page-android`). All input was real OS input: `adb shell input tap/keyevent/swipe`, and `input motionevent DOWN/MOVE/UP` to hold a drag. Bar state came from `dumpsys window` (statusBars and navigationBars `visible=`), the window frame from `dumpsys window windows`, and positions from `screencap` PNGs. Recordings were made with `screenrecord`, and frame timings come from `ffprobe` on the raw 1080p files.
- Books: `Pride and Prejudice` EPUB, `attention.pdf` (15 pages), and `吾輩は猫である` (`neko.epub`, vertical, RTL), all already in the library.
- Settings: I switched Page animations off for checkpoint 6 and then back on (95). Progress stayed on Page the whole time. I changed no system settings.
- Files: full-resolution PNGs are kept for the geometry shots (00–06, 30, 31, 53, 80). The other screenshots are 540 px wide with a 128-colour palette to keep the commit small. `*-frames.png` are strips of recording frames. `rec-*.mp4` are re-encoded to 540 px wide.

## Checkpoints

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Stable geometry (#264) | **Pass.** The window frame is `[0,0][1080,2400]` with chrome hidden and with chrome shown, and `layoutInDisplayCutoutMode=always`. Pride stays on **page 8** with the same text. A pixel diff of hidden vs shown changes only rows 0–282 (toolbar) and 2166–2399 (bottom bar), and rows 283–2165 are identical. Hidden → shown → hidden is pixel-identical. The PDF behaves the same way (diff only in 0–282 and 2166–2399, so 0 px of movement, last time 99 px). The cutout band y 0–136 is painted in the page colour (255,253,248 on the EPUB, 245,241,231 on the PDF), with **no black band**. | 01, 02, 03, 04, 05, 06 |
| 2 | Safe areas (#262) | **Pass.** The running head is at y 162–182, below the 136 px status/cutout inset. The EPUB folio is at y 2290–2316 and the PDF place line at y 2276–2303, both above the gesture strip (y 2337–2400). Last time both were inside it. See Geometry. | 01, 04, 80 |
| 3 | Tap zones (#265) | **Pass.** Pride: 85% → page 9, 15% → page 8. 30%, 50% and 70% each show chrome and bars, and a second tap hides them. The boundaries are at the quarters: 23% → previous, 27% → chrome, 73% → chrome, 77% → next. The PDF gives the same results (85% → 8 of 15, 15% → 7 of 15, middles → chrome). On neko the sides are mirrored: 15% → page 4 (next), 85% → page 3 (previous), and 30% → chrome. | 40–44, 20–23, 80–83 |
| 4 | Idle hide (#265) | **Pass.** Chrome is up at about 1 s (50) and gone at about 4.5 s (51). Polling `dumpsys` put the hide at **3.03 s** and **3.02 s** after the tap in two runs. With the Aa panel open, chrome and bars were still up after 7 s (52, 53). After I closed the panel, chrome hid again about 3 s later (55). | 50, 51, 52, 53, 55 |
| 5 | Page curl (#266) | **Pass, with notes below.** Tap turns curl forward from the right edge and back from the left on the EPUB and the PDF. Each tap turn takes about 0.37 s at a 17 ms median frame interval. Neko curls forward **from the left edge**. Held drags work on all three books: at 70% the curl follows the drag and releasing falls back with no page change, and dragging past the middle to 30% turns the page. The reverse drag behaves the same way for a backward turn. The fold edge tracks the drag distance from the page edge: with DOWN at x 1000 and MOVE to 756 the fold is at about x 836. | rec-1, rec-2, rec-4, rec-5, rec-6; 60, 61, 62–66, 70–79h, 84–88 |
| 6 | Page animations off | **Pass.** With the switch off, a tap turn changes the page in one recorded frame with no curl (rec-7: single frames at 1.42 s and 3.40 s). A held drag shows the page standing still (94 held), and releasing past the middle turns the page at once. I turned the switch back on and confirmed `checked=true`. | 90–95, rec-7 |
| 7 | System Back from the reader with chrome hidden | **Pass.** `dumpsys` reported statusBars `visible=true` at the first poll, **125 ms** after the key event. In rec-8 the bars begin to draw 56 ms after the first changed frame, and the library has its status bar drawn by 192 ms. Last time this took about 1.5 s. | 30, 31, 96, rec-8 |
| 8 | Anything else | See Other observations. | 69, 77, 78, 97, 99, rec-3 |

## Geometry (physical px)

| Item | Where |
|---|---|
| App window, chrome hidden and shown | `frame=[0,0][1080,2400]` in both states |
| Status bar / cutout inset | `[0,0][1080,136]`. The punch hole is at about x 41–106, y 41–105. |
| Gesture bar | `[0,2337][1080,2400]` (63 px) |
| EPUB running head (Pride) | x 377–703, y 162–182 |
| EPUB body text (Pride) | x 64–1016, y 291–2177 |
| EPUB folio "page 8" | x 493–586, y 2290–2316 (21 px above the gesture strip) |
| PDF page (attention, page 7) | full width, y 419–1815 |
| PDF place line "page 7 of 15" | x 455–624, y 2276–2303 (34 px above the gesture strip) |
| Neko running head ("一", the chapter title) | x 526–552, y 173–175 |
| Neko body / folio | x 152–1000, y 274–2183 / x 493–586, y 2290–2316 |
| Chrome overlay when shown | toolbar y 0–282 (status bar included), bottom bar y 2166–2399 (nav strip included) |

## Other observations

1. **PDF desk colour flashes during a forward drag.** As soon as a forward drag starts on a PDF, the desk around the page changes from the PDF desk colour (245,241,231) to the EPUB paper colour (255,253,248). It changes back when the drag ends. Backward drags and tap turns keep the right colour. Seen in 73/74 held, 79g/79h held, and in frames in 78.
2. **First PDF tap turn stalls before the curl.** In rec-4 the first forward tap turn has a **145 ms** gap between frames at the start, and the backward turn has an 80 ms gap. During the gap the place line already reads "page 8 of 15" while page 7 is still drawn with no curl (77, frames 3–5). EPUB and neko tap turns had no gap over 38 ms.
3. **A drag that starts in the system edge zone shows the system bars.** Starting the drag 40 px from the edge (x 1040 or x 40) is inside Android's back-gesture zone. The immersive transient status and navigation bars then slide in, dimmed, over the curl and stay for a moment after release (69-edge40-*, rec-3). The page result was still correct (cancel/commit as expected), and the app's own chrome did not appear. Drags starting at x 1000/80 do not show the bars. The app sets no system-gesture exclusion rects, so this is the OS working as designed, but it is what a user will see if they grab the very edge of the page.
4. **Aa sheet scrim leaves a 10 px strip unscrimmed.** With the Display sheet open, rows y 136–146, the top of the toolbar just under the status bar, keep the toolbar colour (235,229,216) while everything above and below is dimmed (99, 53).
5. **Pride and Prejudice: italic justified lines are still clipped at the right edge**, the same as last time. The last glyph is cut at x 1016 ("attempt", "hampered", "avail", "will", "one") (97). This is EPUB layout, not quiet-page work.
6. No jank in the EPUB or neko curls. The worst gap in the EPUB tap turns was 33 ms, and the median frame interval was 17 ms everywhere. App chrome never appeared over a curl.

## Not done

- No rotation. I did not change the phone's rotation settings.
