# Reader follow-ups on Android (PRs #272–#276)

- Build: `claude/project-thread-r96hxq-verify-all` at `11fbaab7`, `flutter build apk --profile --target-platform android-arm64`
- Device: Pixel 5a (barbet), 1080 × 2400, 420 dpi, gesture navigation
- Installed with `adb install -r` over the existing app. First install time is unchanged (2026-10-28), so the library and reading positions were kept.
- Books: attention.pdf (15 pages) and Pride and Prejudice (EPUB). 吾輩は猫である was not needed.
- I restored the temporary device changes: `show_touches` is unset again, and Page animations is back on.

| # | Item | Result |
|---|------|--------|
| 0 | `ReaderSystemBarsTest` | **PASS**: 12/12, including `turn edges are the middle 200 dp of each gesture zone` (default SDK plus 24/28/29/30/34) |
| 1 | PDF curl start (#272) | **FAIL**: on 6 of 6 taps the "page x of 15" line changes before the curl moves. The curl starts about 470 ms after the tap. |
| 2 | Stage under a curl (#273) | **PASS**: the desk stays (245,241,231) while holding a curl in both directions, and the page falls back on release |
| 3 | Edge drags (#274) | **PASS** at the vertical middle. Near the top and bottom, the bars slide in and the page still turns (details below). |
| 4 | Aa sheet scrim (#275) | **PASS**: rows 120–282 are undimmed (status bar plus the whole toolbar, including 136–146), and the page from y 283 down is dimmed |
| 5 | Regressions | **PASS**: tap zones, 3 s idle hide, Page animations off and Back from a quiet page all work. The app logged no exceptions. |

## 0. Unit test

`./gradlew :app:testDebugUnitTest --tests '*ReaderSystemBarsTest*'` → BUILD SUCCESSFUL, `tests="12" failures="0" errors="0"`
(see `TEST-dev.shosai.shosai.ReaderSystemBarsTest.xml`).

Note: on this machine the plain `./gradlew` command exits 1 and prints nothing. That is because the Nix Flutter
SDK's included Gradle build sits in the read-only store. It works with the same flags that `flutter build` passes:
`--project-cache-dir=$HOME/.cache/flutter/nix-flutter-tools-gradle/052f31d115/cache -Pkotlin.project.persistent.dir=$HOME/.cache/flutter/nix-flutter-tools-gradle/052f31d115/kotlin`.

## 1. PDF curl start (#272): FAIL

### Method

The quiet page was attention.pdf p. 7. I made 3 forward taps at x 918 (85%), then 3 back taps at x 162 (15%), all at y 1200. Then I made one forward and one backward
`input swipe` over 1.5 s. I recorded the screen with `adb shell screenrecord`.

The `input` events do not draw show-touches dots, so I timed the taps another way. The device script writes `date +%s%N` just before and just after
each `input tap` (`recordings/item1-tap-marks.txt`). Each `input tap` takes only 33–40 ms. screenrecord embeds a
Winscope timestamp for every frame (elapsed-realtime ns plus the realtime offset). I checked that offset against
`/proc/uptime` sampling and it agreed within ±7 ms. So every frame has a device wall-clock time.

Times below are measured from when `input tap` returned. The tap itself happened 0–40 ms earlier.

| Tap | Footer line changes | First frame where the curl moves | Line changes early by |
|-----|------------|-------------------|---------------|
| fwd 1 (7→8) | +395 ms | +473 ms | 78 ms |
| fwd 2 (8→9) | +406 ms | +466 ms | 60 ms |
| fwd 3 (9→10) | +391 ms | +471 ms | 80 ms |
| back 1 (10→9) | +404 ms | +467 ms | 62 ms |
| back 2 (9→8) | +393 ms | +407 ms | 14 ms |
| back 3 (8→7) | +408 ms | +424 ms | 16 ms |

- The footer line still changes before the curl on every tap: by 60–80 ms on four taps and by about one frame on the last two back taps.
  See `sheets/item1-pdf-forward-tap1.png` and `sheets/item1-pdf-forward-tap3.png`.
- Tap to first curl frame is about 470 ms forward and 407–467 ms back. Most of that is the 300 ms double-tap timeout.
  The PDF page has double-tap-to-zoom (`lib/reader/view_selection.dart:781`), so a single tap cannot win the gesture
  arena until that timeout ends. Without the timeout, the curl starts about 170 ms after the tap.
  These figures are not directly comparable with last run's 145 ms, which was measured another way.
- **EPUB control, same method** (Pride, `recordings/item5-pride-animations-on-control.mp4`): the curl starts **+38 ms / +27 ms**
  after the tap, and the footer changes in the same frame or later. With animations off, the page swaps in one frame at +35 / +30 ms.
  This confirms the timing method. The delay is specific to the PDF.
- Held drags: the curl first moves about 140–160 ms after the swipe starts. During the drag the footer keeps the old page and changes
  45–47 ms after release, so drags do not show the early change.

## 2. Stage under a curl (#273): PASS

On attention.pdf I dragged forward from x 810 to 594 (75% → 55%) and held, using `input motionevent`. Then I did the same backward from x 270 to 486.

| State | Desk above and below the page (every pixel in rows 150–400 and 1840–2250) |
|-------|-------------|
| rest | (245,241,231) |
| holding a forward curl | (245,241,231), 712,800 of 712,800 pixels |
| holding a backward curl | (245,241,231), 712,800 of 712,800 pixels |

After release, both curls fell back to page 7 (`item2_*_release.png`, `sheets/item2-stage.png`).

## 3. Edge drags (#274)

While the page is quiet, `dumpsys window` shows `mSystemGestureExclusion=SkRegion((0,937,78,1462)(1002,937,1080,1462))`.
The gesture zone is 78 px. The band is y 937–1462. With the chrome shown, the region is empty.
`item3-dumpsys-window.txt` has the InsetsPolicy state while holding and after each drag.

| Book | Drag | While holding | Result |
|------|------|---------------|--------|
| attention.pdf | right edge x 1040, y 1200 → 440 | status/nav HIDDEN | curl followed; turned 7→8 |
| attention.pdf | left edge x 40, y 1200 → 640 | status/nav HIDDEN | curl followed; turned 8→7 |
| Pride | right edge x 1040, y 1200 | HIDDEN | curl followed; turned 8→9 |
| Pride | left edge x 40, y 1200 | HIDDEN | curl followed; turned 9→8 |
| attention.pdf | right edge, y 400 / left edge, y 400 / right edge, y 2000 / left edge, y 2000 | **SHOWING** | dimmed bars slid in. **No Back fired**: the page curled and turned under the bars, which hid again after release |
| Pride | right edge, y 400 / left edge, y 2000 | **SHOWING** | same: bars slid in, the page curled, no Back |
| attention.pdf, chrome shown | right edge, y 1200 | SHOWING (chrome) | **system Back**: back arrow appeared, returned to the Library |
| Pride, chrome shown | left edge, y 1200 | SHOWING (chrome) | **system Back**: back arrow appeared, returned to the Library |

The mid-edge drags pass on both books. The bars no longer slide in over the curl.

Near the top and bottom, Back did not fire. Instead, the first edge swipe on the quiet page revealed the transient bars
(the immersive "swipe to reveal bars" behaviour), and the reader still received the drag and turned the page.
The same injected drags did Back when the chrome was shown, so the back gesture does see `input motionevent`.
Evidence: `sheets/item3-*.png`, `screenshots/e_*`.

## 4. Aa sheet scrim (#275): PASS

On Pride I showed the chrome and opened Aa. I compared column x 540 with the chrome-only frame (`item4_chrome_before.png` vs `item4_aa_sheet.png`):

| y | chrome only | Aa open |
|---|-------------|---------|
| 120–135 (status bar) | (176,172,162) | (176,172,162), unchanged |
| 136–146 | (235,229,216) | (235,229,216), unchanged |
| 150–279 (toolbar) | (235,229,216) | (235,229,216), unchanged |
| 281 (toolbar edge) | (215,208,191) | (215,208,191), unchanged |
| 283–300 (page) | (255,253,248) | (193,191,187), dimmed to 75.5% |

Every row from 120 to 282 is identical, and every row from 283 to 300 is dimmed.

## 5. Regressions: PASS

- Tap zones on quiet Pride: x 950 → 7→8 and 8→9; x 130 → 9→8; the middle shows the chrome.
- Idle hide: 1 s after showing, bars SHOWING and the exclusion is empty. At 3.8 s the chrome is hidden, bars HIDDEN, and the turn edges are back
  (`r_idle_1s.png`, `r_idle_3_8s.png`). An earlier attempt was spoiled by a heads-up notification that arrived at the same moment, so I left out that screenshot.
- Page animations off (Aa → Page animations): forward and back taps swap the page in a single frame, +35 ms / +30 ms after the tap
  (`recordings/item5-pride-animations-off.mp4`, which has 3 frames). I switched it back on afterwards.
- `KEYCODE_BACK` on a quiet Pride page returned to the Library (`r_back_before.png`, `r_back_after.png`).
- Logcat for the app process (pid 7502, whole session): no E or F lines and no Flutter exceptions. There are only routine
  W/I lines (ApkAssets cleanup, hiddenapi, Adreno, WindowOnBackDispatcher).

## Files

- `recordings/`: 540 px wide H.264 of item 1 and the item 5 animation on/off runs, plus the tap timestamp files
- `screenshots/`: Item 2 and 4 screenshots are full resolution, because their colours were sampled. The rest are scaled to 540 px.
- `sheets/`: annotated frame strips and side-by-sides
- `scripts/`: the device scripts and the frame-timing analysis
