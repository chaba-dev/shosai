# Quiet page on Android: device verification

- Build: `main` at `7ddfda8` (#256 and #257). `make android-profile`, installed with `adb install -r` over the existing app, so data was kept.
- Device: Pixel 5a (`barbet`) on Android 14, 1080×2400 at 420 dpi, gesture navigation.
- Input: every action was real OS input (`adb shell input tap/swipe/keyevent`). Bar state was read from `dumpsys window` (statusBars and navigationBars `visible=`), the reader's state from `uiautomator dump`, and positions were measured from `screencap` PNGs.
- Books: `pride.epub` (Gutenberg 1342), `attention.pdf` (arXiv 1706.03762v7), `neko.epub` (vertical Japanese), plus `fixtures/sample.epub` and `fixtures/sample.pdf`. All were added through Add books → system picker → Downloads, multi-selected, then Review books → Import.
- Recordings: `qp-1.mp4` … `qp-4.mp4` cover the whole session in order. They are re-encoded to 540 px wide; the 1080p originals were too big to commit.

## Geometry (physical px)

| Item | Where |
|---|---|
| Camera cutout | Punch-hole at top left: circle centre (73.5, 73), r 32, so x 41–106 and y 41–105. Bounding rect (0,0)–(145,136). |
| Status bar inset | y 0–136 |
| Gesture/navigation bar | y 2337–2400 (63 px) |
| App window, bars hidden | y 136–2400. The cutout band y 0–136 is **letterboxed black**; the app does not draw there. |
| App window, bars shown | y 0–2337 |
| EPUB running head (Pride) | x 377–703, y 162–182. Clear of the hole (57 px below it) and of the black band. |
| EPUB folio "page 6" | x 493–586, y 2353–2379. **Inside the gesture strip.** |
| EPUB folio "1%" | x 520–556, y 2353–2373. **Inside the gesture strip.** |
| PDF place "page 4 of 12" / "page 1 of 15" | y 2339–2366. **Inside the gesture strip.** |
| EPUB body text | x 63–1016, y 291–2245 |

## Checkpoints

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Zones hint on first open; one tap dismisses it without turning | **Pass, with a caveat.** On launch the app restored the last open book (a PDF), and the hint appeared there rather than on pride.epub. A tap on the "Next page" third dismissed it and the page stayed at 4 of 12. Pride, attention and neko then opened without the hint. | 00, 01, 09 |
| 2 | Quiet page: no toolbar, bottom bar or chevrons; system bars hidden | **Pass, with layout issues.** No chrome, and both bars are `visible=false`. The running head is clear of the cutout. The top 136 px are a black letterbox. The folio and PDF place line sit in the gesture strip (see Geometry). | 01, 10 |
| 3 | Middle-third tap: chrome slides over and the page does not move; system bars return | **FAIL.** Chrome and bars appear, but the page moves. On the PDF the page shifts 99 px upward. On the EPUB the text **repaginates**: "page 6" becomes "page 5" and different text is shown, ending where page 6 began. The cause is that the app window changes from y 136–2400 to y 0–2337 when the bars toggle, so the reader viewport changes size. | 02 vs 01, 11 vs 10 |
| 4 | Tap the page: chrome and bars hide | **Pass.** The page returns pixel-identical to its pre-reveal state (EPUB back to page 6). | 03, 12 |
| 5 | Right third next, left third previous, swipe RTL next | **Pass** on the PDF (4→5→4, swipes 4→5→4) and the EPUB (6→7→6, swipes 6→7→6). A tap with 10 px drift also turns the page on both the PDF and the EPUB. | 04, 05, 13 |
| 6 | Show chrome, swipe the toolbar up: it hides | **Pass.** Bars are hidden as well. | 14 |
| 7 | Aa → Progress Percent, then Off, then Page | **Pass.** "1%", then nothing, then "page 6". | 15, 16, 17, 18 |
| 8 | attention.pdf: place line in muted ink under the page; zones turn pages | **Pass**, but the place line is in the gesture strip. Turns: 1→2→3→2, swipe →3. | 25, 26 |
| 9 | neko.epub: left third turns forward; no hint | **Pass.** Left 1→2→3, right →2, swipe LTR →3, swipe RTL →2, 10 px-drift left tap →3. No hint. | 27, 28 |
| 10 | Keyboard via Search, close it: bars return to the right state | **Pass.** Search is only reachable with chrome shown. With the keyboard open, then closed, the bars stay shown while chrome or search is up. After closing search and tapping the page, bars are hidden. On this phone the search panel is drawn below the status bar, not under it. | 19, 20, 21 |
| 11 | Library shows the status bar; Home → recents on the library: still shown; same with a book open and chrome hidden: bars hidden | **Pass.** Extra check: system Back with chrome hidden briefly shows the library with bars still hidden (black top band). They return within about 1.5 s. | 06, 23, 24, 29, 30, 31, 32 |
| 12 | Rotate | Skipped. I didn't want to change the phone's rotation settings. | — |

## Other observations

- **Pride and Prejudice: justified italic lines are clipped at the right edge.** The last glyph is cut at x 1016 ("eminentl", "permittec", "ot", "complet"). See 10 and 11. This is likely EPUB layout rather than quiet page, but it is very visible on this page.
- The reveal is a visible reflow, not an overlay. It undoes the main promise of the quiet page on Android 14. A fix would likely keep the Flutter view a constant size: edge-to-edge (`WindowCompat.setDecorFitsSystemWindows(window, false)`), `layoutInDisplayCutoutMode = shortEdges` (or `always`), and safe-area padding applied in the stage. That would also remove the black cutout band, and the folio and place line could then sit above the gesture inset.

## Not done

- No rotation (checkpoint 12).
- I could not get a true first open of pride.epub with the hint, because the app reopened a previously open PDF on launch and the hint was spent there.
