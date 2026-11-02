# Quiet page on iOS at main 42a03fc: device verification

Build under test: `main` at 42a03fc, which includes #262 (safe areas and a
stable rail), #263 (pointer vs touch, quieter page furniture), #265 (quarter
zones, 3 s touch idle) and #266 (interactive page curl). Run on 2026-11-02 on
Darwin's devices attached to the Mac mini:

| Device | Model | iOS | Logical size | Refresh | Safe area (top / bottom) |
| --- | --- | --- | --- | --- | --- |
| iPhone 15 Pro Max | iPhone16,2 | 27.2 | 430 × 932 pt @3x, portrait | 120 Hz | 59 / 34 pt |
| iPad Air 5 | iPad13,17 | 27.2 | 1180 × 820 pt @2x, landscape | 60 Hz | 32 / 25 pt (the status bar now stays visible on iPad) |

Spec: RFD 12 and `docs/design-system.md` (25/50/25 zones).

## Summary

| # | Checkpoint | iPhone | iPad |
| --- | --- | --- | --- |
| 1 | Safe areas (#262) | **Pass** | **Pass** |
| 2 | iPad rail stays put (#262) | n/a | **Pass** |
| 3 | Page stays put when the chrome shows | **Pass** | **Pass** |
| 4 | Quarter / half / quarter tap zones (#265) | **Pass** | **Pass** |
| 5 | Idle hide after about 3 s; held open by the Display panel (#265) | **Pass** | **Pass** |
| 6 | Page curl (#266) | **Pass, 2 issues** (PDF tap-turn delay; PDF backdrop colour during a curl) | **Pass, 2 issues** (PDF tap-turn delay; shadow and backdrop drop out during a curl) |
| 7 | Page animations off | **Pass** | **Pass** |
| 8 | Other | Italic glyphs clipped at the right edge of the text (already there on 10-31) | Cover and first spread both say `page 1`; no place on the quiet PDF (as before) |

## How it was run

This is the same method as the 2026-10-31 run (`previous-REPORT.md`), with the
harness updated for the new behaviour. The harness is
`quiet_page_ios_test.dart.txt`; the logs are `iphone-run.log.txt`,
`ipad-run1.log.txt` and `ipad-run2-epub.log.txt`.

- An integration test, not committed, drove the production `ShosaiApp` with
  touch taps and drags through `WidgetTester` (pointer kind touch), in English.
  Its data directory was a new temporary directory, so the app's real library
  and settings were never read or written. Pride and Prejudice (Gutenberg 1342,
  EPUB 3), *Attention Is All You Need* (15-page PDF) and 吾輩は猫である
  (`neko.epub`, vertical right-to-left) were bundled as temporary assets and
  imported into that library.
- On both devices the test was built as a **profile** app
  (`flutter build ios --profile -t integration_test/quiet_page_ios_test.dart`),
  installed over the app with `devicectl device install app` and launched with
  `devicectl device process launch --console`. The binding ran with
  `framePolicy = fullyLive`, so the app drew every frame it asked for, as in
  normal use. That keeps curls animating on the device and makes the frame
  timings real.
- At each checkpoint the test printed `SHOT <label>` and held the screen still
  for about 4 s. A watcher on the Mac took a **real device screenshot** with
  `pymobiledevice3 developer dvt screenshot` (about 1.2 s each). The test also
  logged `MediaQuery` padding and the global rects of the stage, tap area,
  selection surface, running heads, folios, toolbar and rail buttons.
- For the chrome-shown screenshots the test rests a finger on the toolbar
  title (`startGesture`, then `cancel`). Otherwise the new 3 s idle timer would
  hide the chrome before the screenshot lands.
- Taps are placed at fractions of `reader-page-tap-area`, the box the
  controller measures them in: the full screen on the iPhone, and the whole
  spread (x 80–1156) on the iPad. Each zone tap started with the chrome hidden.
  The result was read from the painted pages (EPUB canonical start or PDF unit)
  and from the folio.
- Page curls were recorded three ways:
  - whether `reader-page-curl` is in the tree on each frame;
  - in-app frames (`RepaintBoundary.toImage`), copied off the device and
    assembled into the GIFs in `curl/`;
  - real device screenshots while a drag is held still.
- "Same page" was checked from the rects and painted page, and with a pixel
  diff of the device screenshots: rows where any channel differs by more than
  24/255.
- Build workarounds, in a throwaway worktree only, the same as on 10-31:
  - iOS deployment target raised to 15.0 for Runner and the pods (Xcode 27.1
    rejects 13.0);
  - the official Flutter 3.41.5 SDK with a clean, non-Nix environment;
  - `DEVELOPMENT_TEAM` set;
  - CocoaPods from the Nix store on `PATH`.

The iPad EPUB checks were run twice. In run 1 the iPad's first spread after
the cover was the title page and the table of contents. Taps at the vertical
middle of the right page landed on the chapter links (`XXXVII.`), and links
take the tap, so the 85 % taps there did not turn. That is by design, but it
blocked the run's later EPUB steps. Run 2 (`ipad-run2-epub.log.txt`, `QP_TAP_Y=margin`) taps
6 pt below the text block, clear of links, and covered every EPUB checkpoint.
The `ipad-01…14` screenshots are from run 2; `ipad-15…33` (PDF, neko, end) are
from run 1. The iPhone taps were at the vertical middle throughout.

## 1. Safe areas (#262)

**iPhone: pass.** Measured from the logs (pt):

| Item | Rect (x, y, w × h) | Clearance |
| --- | --- | --- |
| EPUB running head `PRIDE. and PREJUDICE` | 152, 66, 126 × 14 → y 66–80 | 7 pt below the 59 pt top safe edge; the island ends about y 48 (on 10-31 it was y 7–21, under the island) |
| EPUB folio `page 7` | 196.5, 877, 37 × 14 → y 877–891 | 7 pt above the bottom safe edge (898); the home indicator is about y 919–924 (on 10-31: y 911–925) |
| PDF place line `page 3 of 15` | 181.5, 872, 67 × 14 → y 872–886 | 12 pt above the bottom safe edge (on 10-31: y 906–920) |
| neko running head `一` | 209, 66, 11 × 14 → y 66–80 | below the safe edge (on 10-31: y 7–21) |
| neko folio `page 3` | 196, 877, 38 × 14 → y 877–891 | above the bottom safe edge |
| EPUB text block (selection surface) | 0, 87, 430 × 782 → y 87–869 | inside the safe area (on 10-31: y 28–903) |

Annotated: `iphone/iphone-03-epub-quiet-annotated.png`,
`iphone/iphone-15-pdf-quiet-annotated.png`,
`iphone/iphone-24-neko-quiet-annotated.png`. The red bands are the exact safe
areas from `MediaQuery`. The island and home-indicator outlines are approximate,
because system overlays do not appear in device screenshots.

Because the text block is now inside the safe area, an iPhone page holds fewer
lines than on 10-31: page 7 now ends where the 10-31 page 7 was halfway down.

**iPad: pass.** The running heads are at y 80–92 and the folios at y 735–747
(EPUB `page 13 · page 14`, neko `page 6 · page 5`). Both are well clear of the
32 pt status bar and the 25 pt home-indicator inset, which starts at y 795.
Annotated: `ipad/ipad-03-epub-quiet-annotated.png`.

**Behaviour change on iPad:** the status bar no longer hides while the page is
quiet. The clock, VPN and battery stay at the top, and the top inset stays
32 pt. This is deliberate in #262 (`lib/reader/view.dart`: "Only phones hide
the system status bar with reader chrome … Keep it visible in either
orientation"), and it is what keeps the rail and page still. On 10-31 the iPad
hid it.

## 2. iPad rail (#262): pass

The rail buttons' rects are identical in the quiet, chrome-shown and
chrome-hidden states: Library (6, 94), Notes (6, 146), Search (6, 250),
Settings (6, 302) and Add books (6, 735), each 44 × 44. The rail strip
(x 0–56 pt) is pixel-identical between `ipad-03` and `ipad-04` (EPUB),
`ipad-15` and `ipad-16` (PDF), and `ipad-24` and `ipad-25` (neko). On 10-31 it
moved 32 pt on every toggle.

## 3. The page stays put when the chrome shows: pass

| Device | Book | Quiet vs chrome shown | Quiet vs hidden again |
| --- | --- | --- | --- |
| iPhone | EPUB / PDF / neko | Only rows y 21–36 (status bar), 64–115 (toolbar; the running head fades into it) and 833–891 (bottom bar) differ. Rows 115–833 are identical. Stage, tap area, surface, painted page and folio are unchanged. | Pixel-identical |
| iPad | EPUB / PDF / neko | Only rows y 23–89 (toolbar) and 759–820 (bottom bar) differ. The page area, y 89–759, is identical. Rects are unchanged. | Pixel-identical |

Evidence: `iphone-03/04/05`, `iphone-15/16/17`, `iphone-24/25/26`, and the same
numbers for the iPad.

## 4. Tap zones (#265): pass

The tap area is the whole width on the iPhone (430 pt) and the whole spread on
the iPad (x 80–1156, 1076 pt). Each tap started with the chrome hidden.

| Tap at | EPUB iPhone | PDF iPhone | neko iPhone | EPUB iPad | PDF iPad | neko iPad |
| --- | --- | --- | --- | --- | --- | --- |
| 15 % | previous (7→6) | previous (3→2) | **next** (3→4) | previous (13–14→11–12) | previous | **next** (5–6→7–8) |
| 23 % | previous | previous | **next** | previous | previous | **next** |
| 27 % | chrome | chrome | chrome | chrome | chrome | chrome |
| 30 % | chrome | chrome | chrome | chrome | chrome | chrome |
| 50 % | chrome | chrome | chrome | chrome | chrome | chrome |
| 70 % | chrome | chrome | chrome | chrome | chrome | chrome |
| 73 % | chrome | chrome | chrome | chrome | chrome | chrome |
| 77 % | next | next | **previous** | next | next | **previous** |
| 85 % | next (6→7) | next (2→3) | **previous** (4→3) | next | next | **previous** |

"chrome" means the toolbar and bar appeared and the page did not change. neko
is mirrored as expected. Screenshots: `*-zone-15`, `*-zone-50`, `*-zone-85`.

The zones hint shows on the first EPUB open in the temporary library. Its
columns measure **0–25 %, 25–75 % and 75–100 %** of the tap area on both
devices: 107.5 / 215 / 107.5 pt on the iPhone, and 269 / 538 / 269 pt across
the whole spread on the iPad. One tap at 50 % dismissed it without turning or
showing the chrome. Evidence: `iphone-02-epub-hint.png` and
`ipad-02-epub-hint.png`.

## 5. Idle hide (#265): pass

The time from a middle tap until the chrome hid on its own, polled every 50 ms:

| | EPUB | PDF | neko |
| --- | --- | --- | --- |
| iPhone | 3037 ms | 3335 ms | 3036 ms |
| iPad | 3057 ms | 3331 ms | 3060 ms |

PDF is about 0.3 s slower on both devices but still about 3 s.

With Aa (Display) open, the chrome and panel were still up after 6 s, sampled
every 100 ms. On the iPhone it is a bottom sheet over the page; on the iPad it
is a docked panel under the toolbar. Evidence:
`iphone-09-epub-display-panel-6s.png` and `ipad-09-epub-display-panel-6s.png`.

## 6. Page curl (#266): pass, with two issues

**Tap turns.** These are the frames with `reader-page-curl` in the tree after
a tap, and when the curl first and last appeared:

| | EPUB fwd / back | PDF fwd / back | neko fwd / back |
| --- | --- | --- | --- |
| iPhone | 26–334 ms / 26–325 ms | **373–697 ms / 395–703 ms** | 22–313 ms / 20–319 ms |
| iPad | 24–374 ms / 25–375 ms | **406–755 ms / 396–760 ms** | 32–232 ms / 24–374 ms |

EPUB curls forward from the right edge. neko curls from the left. On the iPad
spread the leaf turns over the spine (`curl/ipad-*-curl.gif`).

**Held drag.**
1. The drag started at 95 % (neko: 5 %).
2. It moved to 70 % on the iPhone (neko: 30 %), or to 75 % across the iPad
   spread (40 % of one leaf; neko 25 %), and held still.
3. With the drag held, the curl is drawn and follows the finger, and the page
   does not change (`*-curl-held.png`).
4. Released there, it falls back: the curl is gone, the place is unchanged, and
   the screenshot is pixel-identical to the quiet page. On the iPad only the
   clock differs.
5. A drag past the middle of the leaf (iPhone to 35 %; iPad to 55 %; neko
   mirrored), held for 0.3 s and released, turned the page, 7→8 on the iPhone.

This passes for EPUB, PDF and neko on both devices: `*-curl-fell-back.png`
and `*-curl-turned.png`. The curl follows the finger's movement, not its
position. With the drag held at 70 % on the iPhone, the fold sits at about
75 %, offset by the 5 % gap between the start and the edge. That reads
naturally.

**Frame timing.** These are `FrameTiming` figures in the profile build, over
8 tap turns back and forth after one warm-up turn.

| | Budget | EPUB build / raster p95 (max) | PDF | neko | Frames over budget |
| --- | --- | --- | --- | --- | --- |
| iPhone | 8.3 ms (120 Hz) | 0.40 / 1.12 ms (11.2 / 2.2) | 0.45 / 0.54 ms (3.9 / 1.2) | 0.41 / 3.92 ms (7.5 / 4.2) | EPUB 2 of 552; PDF 0 of 572; neko 0 of 552; none over 16.7 ms |
| iPad | 16.7 ms (60 Hz) | 0.64 / 2.87 ms (7.7 / 3.6) | 0.91 / 1.57 ms (5.4 / 2.4) | 0.62 / 7.41 ms (14.7 / 9.1) | 0 |

The curls are smooth on both devices.

**Issue 6a: PDF tap turns start late.** A PDF tap turn waits about 0.4 s
before the curl starts, on both devices. EPUB and neko start within about
25 ms. During that wait the old page stays still, but the place line already
reads the new page: see the in-app frames
`curl/iphone-pdf-tap-0-inapp.png` (`page 3 of 15`, before the tap) and
`curl/iphone-pdf-tap-1-inapp.png` (page 3 still drawn, the line says
`page 4 of 15`). The cause is likely the wait for the incoming page's raster.

**Issue 6b: the page surround changes during a curl.** It changes for as long
as the curl is drawn (held or animating) and returns on release.
- **iPad EPUB and neko:** the spread's drop shadow below the paper disappears.
  At (200, 800) pt the shadow pixel (159, 152, 140) becomes backdrop (220, 213,
  196). Compare `ipad-05-epub-chrome-hidden.png` with
  `ipad-10-epub-curl-held.png`.
- **iPad PDF:** the whole beige stage backdrop and the page shadow turn
  paper-white (255, 253, 248). This is clearly visible: compare
  `ipad-15-pdf-quiet.png` with `ipad-21-pdf-curl-held.png`.
- **iPhone PDF:** the surround above y 859 pt changes from (246, 241, 230) to
  (255, 253, 248). The band below it, behind the place line, stays beige,
  which leaves a seam at 859 pt (`curl/iphone-pdf-curl-surround-seam.png`).
- **iPhone EPUB and neko:** no change; the page is full-screen paper.

GIFs: `curl/{iphone,ipad}-{epub,pdf,neko}-curl.gif` play these in order:
1. a tap turn (in-app frames);
2. the slow drag to the held point (in-app);
3. the device screenshot held still;
4. the device screenshot after release (fallen back);
5. the drag past the middle (in-app);
6. the device screenshot after release (turned).

The in-app frames are the app's own render (`toImage`), not a screen
recording. This Mac has no ffmpeg and no screen-capture route for the
devices. They are downscaled to 320 / 560 px with 48 colours to keep the files
small.

## 7. Page animations off: pass

In Aa, Page animations was switched off, and the switch reads `false`
(`*-13-epub-animations-off-panel.png`). A tap turn then changed the page with
**no curl frame at all**: 0 of 36 frames on the iPhone, 0 of 28 on the iPad,
pages 8→9 and 15–16→17–18. Switched back on, the switch reads `true`
(`*-14-epub-animations-on-panel.png`) and the next turn curled again (7 and 4
curl frames). The setting was left on.

## 8. Other findings

- **iPhone: italic text is clipped at the right edge of the text column.** The
  overhang of the last glyph is cut by a hard vertical clip at about x 406 pt:
  `gradual`, `I` in "and I", `know`, `for`, `prove`, `it` in the introduction
  of Pride and Prejudice (`iphone-03-epub-quiet.png`, right edge). The same
  clipping is in the 10-31 screenshot, so it is not new.
- **iPad EPUB numbering:** the cover shows alone with folio `page 1`. The next
  spread (title page and contents) reads `page 1 · page 2`, so `page 1`
  appears twice. Both have canonical start 0.
- **iPad PDF:** there is still no folio or place line while the page is quiet,
  as on 10-31. It is visible only in the bottom bar.
- **iPad, first spread:** the vertical middle of the right page is all
  chapter links, so a tap there does not turn. Links win, by design. I did not
  check what each link tap did.
- No exceptions were logged in any run.

## State left on the devices

- Both devices have a normal profile build of `main` (42a03fc, built with the
  workarounds above and no test assets) installed over the app and launched.
  The app was never deleted.
- **iPhone:** it shows the library (Japanese UI, 21 books). That is the app's
  real data container, which the tests never opened. At the start of this
  session the iPhone was showing a Shōsai library with 2 books in English, so
  something other than this run changed that container or showed that screen.
- **iPad:** after launch the app reopened the last book in its real library,
  `Physical Public Curl`, a synthetic PDF that is not from this run, rather
  than the library page. One tap on Library in the rail goes back.
- **Storage:** the first install of main on the iPad failed for lack of space
  (60 MB free, 100 MB needed). I deleted the test folders this harness leaves
  in the app's `tmp/`: `qp-books-*`, `qp-data-*` and `qp-frames-*`, 15 on the
  iPad and 5 on the iPhone, including those left by the 10-30/10-31 runs.
  Nothing else was deleted. The `shosai-demo-*` folders in `tmp/` and the real
  library were not touched. No system settings were changed.

## Re-running

1. Copy `quiet_page_ios_test.dart.txt` to
   `integration_test/quiet_page_ios_test.dart`.
2. Put `pride.epub`, `attention.pdf` and `neko.epub` in `qp-books/` and list
   that folder under `flutter: assets:`.
3. Apply the build workarounds above.
4. Build and install:
   `flutter build ios --profile -t integration_test/quiet_page_ios_test.dart --dart-define=QP_DEVICE=ipad`
   (optionally `--dart-define=QP_BOOKS=epub --dart-define=QP_TAP_Y=margin`),
   then `devicectl device install app`.
5. Run `devicectl device process launch --console --terminate-existing dev.shosai.shosai`,
   piping the output through a watcher that runs
   `pymobiledevice3 developer dvt screenshot --udid <udid> --userspace <label>.png`
   for each `SHOT <label>` line.
6. Copy the in-app frames off the device with
   `devicectl device copy from --domain-type appDataContainer --domain-identifier dev.shosai.shosai --source tmp/<qp-frames-…>`,
   taking the folder name from the log's `FRAMES` line.
