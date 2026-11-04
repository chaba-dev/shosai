# PR #290 Columns on a real iPhone

- **Device:** iPhone 15 Pro Max (iPhone16,2), iOS 27.2, Japanese UI, USB
- **Build:** `feat/pdf-columns-reader` at **19b6101f**. This is newer than the c86db59 in the brief and adds `e53b1c62 fix(reader): honor Columns progress display preference` and `19b6101f test(reader): cover enlarged Columns touch panning`. It is a signed Profile build, installed over the existing app. Library and books were kept: 21 books before, 23 after.
- **Papers:**
  - Thrift (2007), 8 pages, two columns. It was already in the library as `07-Thrift-Scalable-Cross-Language-…`.
  - ResNet (arXiv 1512.03385v1), 12 pages, two columns. Imported.
  - Attention Is All You Need (arXiv 1706.03762v7), 15 pages, one column. Imported.
- **Date:** 2026-11-04

## How this was driven (read this before trusting the numbers)

- Signing an XCUITest runner needs an Xcode account, and there is none on this Mac session. So for the test run only, I installed a build with a verification entrypoint (`lib/verify_main.dart`, not committed; copy kept in my scratchpad). It is the production app plus a loopback socket. The socket injects real touch `PointerDown/Move/Up` events into Flutter's `GestureBinding` and hands PDF paths to the app's own "opened documents" import path.
- Screenshots come from the device framebuffer through the iOS accessibility-audit service, at 1290×2796.
- The recording is a macOS CoreMediaIO capture of the iPhone screen over USB: 60 fps, 1290×2796. Apple's capture replaces the status bar with "9:41".
- At the end I reinstalled the normal `main.dart` Profile build of 19b6101f. I also restored Zoom = Fit page and Page animations = on. That build is what is on the phone now.
- **Hardware cut-outs do not show in screenshots.** The Dynamic Island findings below come from measuring layout against the island's position (about x 152–278 pt, y 11–48 pt on this model). The code supports them: `view_columns.dart` applies no `MediaQuery` padding. I did not photograph the island.

## Pass/fail per spec rule

| Spec rule (RFD 12 / PR #290) | Result | Evidence / note |
|---|---|---|
| Display › Zoom offers Columns / Fit width / Fit page | **PASS** | `03-aa-panel-columns.png` (段組み / 幅に合わせる / ページに合わせる) |
| Columns shows one text column at a time, fitted to the screen width | **PARTIAL** | Works on pages the engine detects: Thrift p1, 3, 4, 5, 8 and ResNet p2, 9, 10. **Thrift p2, p6, p7 and ResNet p1, 3–8, 11, 12 fall back to a whole page shrunk to the width**, which is unreadable. See `awkward/*fallback*.png` |
| Strip runs across columns and pages | **PASS** | `thrift-all-screens/` |
| Screens break between lines (no line split) | **PASS** | OCR of the last and first lines across all 13 Thrift and 12 ResNet screen changes: no split, repeated or skipped line |
| Short rule at a column change | **PASS** | `06-columns-column-change-rule.png`. There is no rule when a screen break falls exactly on the column change, which is fine. One rule shows up inside the right column of Thrift p8, between "briefly described:" and the bullet list |
| Page-number band at a page change | **PASS** | `07-columns-page2-band.png`, `07b-columns-page3-band.png` |
| Outer-quarter tap / swipe moves one screen | **PASS** | Recording 10–28 s |
| Middle tap shows chrome | **PASS** | `04-columns-chrome-shown.png`. Chrome hides after 3 s, which is the existing touch timer (`_scheduleChromeHide`) |
| Page animations slide, no curl | **PASS** | A vertical slide of about 0.37–0.43 s. With animations off the change is instant (recording 36–39 s, `awkward/slide-animation-frames.png`) |
| Folio "page x of y" with a small page outline | **PARTIAL** | Present, and the outline marks the current column area. But: (a) it sits behind the Dynamic Island; (b) it names only the page at the top of the screen, so Thrift p2 and p7 never appear (folio goes 1 → 3 and 6 → 8) |
| Choice of fit is kept | **PASS** | ResNet opened directly in Columns after Thrift was set to Columns, so the choice looks global |

## Problem checks

| Check | Result | Detail |
|---|---|---|
| Text cut at screen edges | **PASS at 100%** / by design at 125% | At 100% every column fits. One step up (125%) cuts every line at the right edge, so you must pan sideways on every line (`11-…`, `12-…`). Panning works. With chrome shown, the line under the header is sliced, as you'd expect from an overlay |
| A line split across screens | **PASS** | None found |
| Wrong reading order | **PASS** on detected pages | Left column, then right column, then the next page. Footnote 1 sits after the p1 left column, matching the PDF |
| Blurry / upscaled text | **PASS** | Crisp at 3x (`awkward/fallback-page-text-at-1x-crop.png`). Fallback pages are sharp but too small to read |
| Folio wrong | **FAIL (minor)** | Pages that start mid-screen are never named. See above |
| Safe-area overlap | **FAIL** | Folio text at y ≈ 8–23 pt, x ≈ 157–275 pt is entirely inside the Dynamic Island. The title on screen 1 starts at y ≈ 35 pt, under the island's lower edge. The last line reaches y ≈ 925 pt, under the home indicator (`awkward/folio-and-title-under-dynamic-island-crop.png`, `awkward/last-line-under-home-indicator-crop.png`). `lib/reader/view_columns.dart` lays out the header and strip with no `viewPadding` |
| Slow / janky | **PASS** | A screen change starts on the frame after the touch and slides for about 0.4 s. Switching to Columns re-renders in under 0.1 s on Thrift. No stalls in the 60 fps capture |
| Crashes | **PASS** | None across about 120 interactions and 3 papers |

## Reading experience

I read every screen of Thrift (14 screens) and ResNet (13 screens) on the device in Columns. I checked text continuity with OCR at every screen change.

- **Default text size.** Comfortable. A 10 pt Times column fitted to 400 pt gives a line pitch of about 16.5 pt, close to iOS body text, with about 58 characters per line.
  - Thrift: 14 screens for 8 pages. Detected pages take about 2–2.5 screens each; each fallback page takes about 1.
  - ResNet: 13 screens for 12 pages, but only 3 of those pages are real column reading.
- **Does each tap land where the eye expects?** Yes on detected pages. The next line is at the top, nothing repeats, nothing is skipped, and there is no re-finding your place. Two things break the flow:
  - **Stranded headings.** A heading ends the screen and its text starts on the next one: "2. Types" (`06-…`), "3.2.3 Utilities" (`07b-…`), "7.11 TFileTransport" (`awkward/thrift-heading-stranded-7-11.png`), and ResNet "PASCAL VOC".
  - **Blank bottoms.** Breaks seem to happen per text block rather than per line, so a screen can end with about 130 pt empty (`06-…`). That costs extra screens.
- **Column and page changes.** The page band is clear and quiet. The column rule is subtle, which is good. What jars is a page band followed by a **whole shrunken page**: Thrift p2 straight after the abstract, and p6–p7 in the middle of the paper. You can't read on; you have to switch to Fit page and pinch.
- **Figures, tables, code, footnotes, equations:**
  - Thrift code listings read very well. Monospace layout is kept, and a listing that wraps across PDF columns gets a column rule, which matches the source.
  - The footnote is fine.
  - The ResNet Figure 2 band (full-width, at the top of p2) is readable.
  - Every ResNet page with figures or tables (p3–8, p11–12), and the arXiv sidebar page p1, falls back to a whole page. Tables and figures are unreadably small there, and so is the body text on those pages.
  - I couldn't judge equations: the ones in ResNet are all on fallback pages.
  - The single-column Attention paper falls back to whole pages at fit width with full margins. That is no better than Fit width, and body text is about 6 pt (`14-…`, `14b-…`, `14c-…`).
- **Slide animation.** The 0.4 s vertical slide helps on the first few taps: you see the text move up. After that it slows a steady reading rhythm a little. Off feels snappier, and the band and rule already mark the changes. A shorter slide (about 0.2 s) would be better.
- **Folio and outline.** The outline is a good idea: it shows which column of the page you are in. On this iPhone it is hidden by the Dynamic Island, so in practice it isn't useful yet. It is also tiny: 12×15 pt.
- **When I'd rather be in Fit page:**
  - Every fallback page, which is 3/8 of Thrift and 9/12 of ResNet.
  - Getting an overview of a figure plus its caption.
  - Jumping between distant sections.
- **Time compared with pinch-zooming in Fit page.** I estimated this from gesture counts; I didn't time a human reader. In Fit page, a two-column page needs a pinch to about 2.3x, then roughly 6–8 pans: down the left column, back up and across, down the right column. That is about 4x more gestures per page than Columns, and you re-find your place at each column top. On fallback pages Columns is slower than Fit page: you switch mode, pinch, read, then switch back.

**Verdict: needs changes.**

The core strip is good on pages it detects: line-safe breaks, correct order, crisp, fast. But on real papers most figure and table pages, and even some text-only pages (Thrift p2/p6/p7), drop to unreadable whole pages, and the folio sits behind the Dynamic Island.

### Top 3 changes that would most improve reading

1. **Make fallback pages readable, and fall back less.**
   - Find out why text-and-code-only Thrift p2/p6/p7 fail detection. Likely causes are the ink-ownership check or `hasUnboundedGraphics` in `lib/reader/pdf/columns.dart`.
   - On figure and table pages, keep the text columns and show uncertain graphics as full-width bands instead of giving up on the whole page.
   - When a whole page is unavoidable, show it fit to the text block (margins trimmed) with pan and zoom, not shrunk to the full width.
2. **Respect safe areas.** Put the folio and strip top below `MediaQuery.viewPadding.top`, or move the folio to the bottom. Keep the last line above the home-indicator inset.
3. **Break screens per line and keep headings with their text.** Fill each screen to its last whole line, and never end a screen on a heading. This removes the stranded headings and blank bottoms, and saves screens.

Smaller items:

- Name every page that appears on a screen in the folio (for example "2–3 of 8").
- Shorten the slide.
- At more than 100%, the per-line sideways panning makes Columns impractical. Consider offering Fit width at that point.

## Side observations (outside Columns)

- After ResNet was opened, its library card shows both **未読** and **読書中** (`awkward/library-resnet-shows-unread-and-reading.png`).
- After reading Thrift to the end and back to p3 in Columns, the library's 読書中 card still says 13%. Reopening from that card opened p1 in Fit page. After the final reinstall it resumed at p5 correctly.
- The Aa panel shows "300%" next to −/+ in Fit page. It is unclear what that number means there.
- **Signing:** the only provisioning profile on this Mac for `dev.shosai.shosai` **expires 2026-11-04 20:45 UTC**. After that, the installed build will not launch until it is re-signed. This session has no Xcode account ("No Accounts"), so it can't renew the profile.

## Files

- `01-thrift-default-fit-page.png`: default view on open (Fit page)
- `02-aa-panel-fit-page.png`, `03-aa-panel-columns.png`: the Aa panel before and after choosing Columns
- `04-columns-chrome-shown.png`: chrome over Columns
- `05-columns-screen1-title-left-column.png`: screen 1, title and left column
- `06-columns-column-change-rule.png`: column-change rule (also shows a stranded heading and blank bottom)
- `07-columns-page2-band.png`: page-2 band (p2 then falls back to a whole page)
- `07b-columns-page3-band.png`: page-3 band into detected columns
- `08-night-aa-panel.png`, `09-night-columns.png`: Night theme
- `10-aa-text-125.png`, `11-columns-text-125.png`, `12-columns-text-125-panned.png`: text size stepped up once, and panning
- `13-aa-page-animations-off.png`: Page animations off
- `14-single-column-attention-columns.png`, `14b-…-screen2.png`, `14c-…-fit-width.png`: the single-column paper
- `columns-demo-small.mp4` (the full-resolution 163 MB `columns-demo.mov` stays on the Mac at ~/workspace/shosai-evidence/pdf-columns-pr290/): open → Columns → 8 forward taps → 2 back → swipe → animations off → 2 taps
- `thrift-all-screens/`, `resnet-all-screens/`: every Columns screen plus contact sheets
- `awkward/`: every awkward moment cited above
