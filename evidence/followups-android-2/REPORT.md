# Reader follow-ups on Android, round 2 (54637b3)

- Build: `claude/project-thread-r96hxq-verify-all` at `54637b39`, `flutter build apk --profile --target-platform android-arm64`
- Device: Pixel 5a (barbet), 1080 × 2400, gesture navigation
- Installed with `adb install -r` over the existing app. First install time is unchanged (2026-10-28), so the library is kept.
  I moved Pride and Prejudice's place while testing and put it back afterwards (1%, the "delicate for pit and gallery" page). attention.pdf is back on p. 7.
- Settings: show-touches was on during the run and is now off again. Text size ended at 90% and line spacing at 1.6×, as before.

| # | Item | Result |
|---|------|--------|
| 1 | PDF tap turns (#272) | **PASS**: the curl first moves 64–178 ms after the tap (was 407–473 ms). The page line stays on the old number until the curl is moving, then crossfades. Double-tap zoom in the middle still works. |
| 2 | EPUB book-wide numbers (#277) | **PASS, with one caveat**: numbers run on across chapters, chapter opening pages have no running head, the status line shows "NN%" while uncounted and never "page 0", and text size changes recount. The caveat: a page reached by a Contents jump showed a provisional number that later settled to a different value. |
| 3 | Quick regression | **PASS**: EPUB tap turns, PDF swipes, middle tap shows the chrome, Back to Library. The app logged no errors. |

## 1. PDF tap turns

### Method

Same method as round 1. The quiet page was attention.pdf p. 7. I made 3 forward taps at x 918 and 3 back taps at x 162, all at y 1200, recorded with `adb shell screenrecord`.
The device writes a `date +%s%N` mark around each `input tap` (`recordings/item1-tap-marks.txt`). Frame times come from the Winscope
timestamps that screenrecord embeds. Times are measured from when `input tap` returned; the tap itself happened 32–67 ms before that.

| Tap | First changed frame (no motion yet) | **First frame where the curl moves** | Page line |
|-----|-----------------------------------|----------------------------------|-----------|
| fwd 7→8 | +101 ms | **+178 ms** | old number until about +280 ms, crossfade until about +500 ms |
| fwd 8→9 | +58 ms | **+142 ms** | old number while the curl starts, crossfade during the turn |
| fwd 9→10 | +68 ms | **+152 ms** | old number until +168 ms, crossfade +185 to +370 ms, "page 10" at +420 ms |
| back 10→9 | +42 ms | **+74 ms** | old number while the curl starts, crossfade during the turn (`sheets/item1-pdf-back-tap1.png`) |
| back 9→8 | +32 ms | **+72 ms** | same |
| back 8→7 | +46 ms | **+64 ms** | same |

- The 300 ms double-tap wait is gone. Tap to first curl frame is now 64–178 ms, down from 407–473 ms.
- The page line no longer changes before the curl. It keeps the old number while the leaf starts to lift, then crossfades to the new one
  as the leaf turns (the enlarged line under each frame in `sheets/item1-pdf-*.png`).
- **What is left in the delay:** every tap first produces a frame where the page changes but nothing moves yet, 32–101 ms after the tap.
  That is the page being swapped for the turn snapshot. The curl starts on the next frame or a few frames later. Forward taps are about 80–100 ms slower than back taps
  (142–178 ms vs 64–74 ms), and on a forward tap the leaf appears already partly lifted (f47 in `sheets/item1-pdf-fwd-tap3.png`).
  The extra time on forward taps seems to go into preparing the incoming page's snapshot before the leaf moves.
- Double tap in the middle (two taps 80 ms apart at 540,1200) zooms in, and a second double tap returns to fit (`sheets/item1-double-tap-zoom.png`).
  Taps less than about 40 ms apart count as two single taps (Flutter's minimum double-tap interval), so the first attempt showed and hid the chrome instead.

## 2. EPUB book-wide numbers (Pride and Prejudice, Pages mode)

**Chapter boundary.** I used Contents → "Go to chapter 3 of 9". On that chapter's opening page, a turn back and then forward gave
**page 112** (last page of chapter 2, running head "CHAPTER X.") → **page 113** (chapter 3's opening page, **no running head**) → **page 114**
(running head "Piling up the fire. CHAPTER XI."). The numbers keep counting across the spine boundary (`sheets/item2-chapter-boundary.png`).
Paging later gave 108 → 109 → 110 → 111 → 112 consistently. Chapter I is inside the second spine file and starts partway through page 30 ("4% · page 30").

**Contents jump to a late chapter (chapter 8 of 9).** With the chrome shown, the status line read just **"98%"** from about 0.8 s to 3.2 s,
never "page 0". The page then read **"page 622"** (`sheets/item2-jump-late-chapter-status.png`).

**Caveat: a provisional number that changed later.** Right after the first "Go to chapter 3" jump, the chapter's opening page read **"16% · page 117"**
with the chrome shown and **"page 117"** in quiet mode, 5 s later. After paging back and forward, the same page read **113**.
Later, after I briefly left the app and came back, the reader sat blank and uncounted for a while, then recounted: the page that had read 114 read **111**, and from then on paging was consistent.
So a page reached by a Contents jump can show a number that is not the final one. The rule is meant to be "blank until counted",
not an estimate. Screenshots: `b_ch3_start_chrome`, `b_ch3_start_quiet` (117), `b_ch3_start_again` (113).

**Text size.** Changing 90% → 100% in Aa recounted the page from 112 to **138** within 2.9 s, and it stayed there for 16 s (`sheets/item2-text-size-up.png`).
Changing 100% → 90% showed the old "page 138" for about 0.4 s, then just **"16%"** at 0.8–1.2 s, then settled on **"page 113"** at 1.6 s
(`sheets/item2-text-size-down-status.png`). It never showed "page 0".

## 3. Quick regression

- EPUB tap turns: right quarter forward and left quarter back, 108 ↔ 112, as above.
- PDF swipes on attention: a left swipe gives 7 → 8 and a right swipe gives 8 → 7 (`reg_pdf_swipe_*`).
- A middle tap shows the chrome (`reg_pdf_middle_chrome`).
- Back from a quiet page returns to the Library (`reg_back_*`).
- Logcat for the app process (pid 15082, whole session): no E or F lines and no Flutter exceptions. There are only routine W/I lines (ImeTracker, ApkAssets, Adreno, WindowOnBackDispatcher).

## Note

Doorbell heads-up notifications arrived several times during the run. Taps I made near the top of the screen to keep the chrome open landed on one of them,
which opened the Google Home / Nest app at its "Your Nest devices have a new home" page. I left it with Back and touched nothing else in it.
Those screenshots are left out.

## Files

- `recordings/`: `item1-pdf-tap-turns.mp4` (540 px) and `item1-tap-marks.txt` (device timestamps around each tap)
- `screenshots/`: 540 px
- `sheets/`: frame strips with the enlarged page line, and side-by-sides
- `scripts/`: the device tap script, the frame-timing analysis and the strip builder
