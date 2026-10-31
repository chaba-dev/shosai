# Quiet page on iOS: device verification

Build under test: `main` at 7ddfda8 (PRs #256 and #257), run on
2026-10-30 on Darwin's devices attached to the Mac:

| Device | Model | iOS | Logical size | Safe area (top / bottom) |
| --- | --- | --- | --- | --- |
| iPhone | iPhone 15 Pro Max (iPhone16,2) | 27.2 | 430 × 932 pt @3x | 59 / 34 pt |
| iPad | iPad Air 5th gen (iPad13,17) | 27.2 | not measured (see below) | not measured |

## How it was run

- An integration test that was not committed
  (`integration_test/quiet_page_ios_test.dart` in a throwaway worktree)
  drove the production `ShosaiApp` with real touch taps and drags through
  `WidgetTester`, in English. Its data directory was a fresh temporary
  directory (`applicationCoreOwner(applicationSupportDirectory: …)`), so the
  library and settings in the app's real container were not read or changed.
- The books were bundled into that test build as temporary assets and imported
  into the temporary library: Pride and Prejudice (Project Gutenberg 1342, EPUB 3
  with images), *Attention Is All You Need* (arXiv 1706.03762v7, 15 pages),
  吾輩は猫である (`tour-books/neko.epub`, vertical right-to-left) and
  `fixtures/sample.pdf`.
- At each checkpoint the test printed `SHOT <name>` and held the screen still for
  5 s. A watcher on the host saw each marker and took a **real device
  screenshot** (`pymobiledevice3 developer dvt screenshot`), so the status bar in
  the screenshots is the real one. The test also logged `MediaQuery.padding` and
  `viewPadding` and the global rects of `reader-stage`,
  `reader-selection-surface`, `reader-running-head`, `reader-folio`, the
  toolbar and the phone bar.
- "Same page" was checked three ways: the folio text, the
  `reader-selection-surface` rect, and a pixel diff of the device screenshots
  (rows that differ by more than 24/255).

### Build workarounds (worktree only, not committed)

- Xcode on this Mac is 27.1. It rejects iOS deployment target 13.0, which
  `main` sets for Runner and which the pods inherit (`The iOS deployment target
  'IPHONEOS_DEPLOYMENT_TARGET' is set to 13.0, but the range of supported
  deployment target versions is 15.0 to 27.1.x`). The test build raised it to
  15.0 in `project.pbxproj` and the Podfile `post_install`. **`main` does not
  build for iOS with Xcode 27.1 as it is.**
- `flutter` from the Nix dev shell (`.agents/dev`) fails to link the iOS app
  (`Unknown options: -Xlinker -dynamiclib …`: the Nix linker wrapper). The
  official Flutter 3.41.5 SDK with the Nix compiler variables removed, which is
  what `scripts/build-flutter-ios.sh` does, worked.
- `DEVELOPMENT_TEAM = NALL3XDPUR` was set in that worktree only.

## iPhone 15 Pro Max (portrait)

| # | Checkpoint | Result | Evidence |
| --- | --- | --- | --- |
| 1 | First EPUB open shows the zones hint; one tap dismisses it without turning | **Pass.** The hint covered the cover page. A tap on the right third dismissed it; the folio stayed `page 1` and the chrome stayed hidden. | `iphone-02-epub-hint.png`, `iphone-03-epub-hint-dismissed.png` |
| 2 | Quiet EPUB page: status bar hidden; running head, first line and folio vs Dynamic Island and home indicator | **Status bar: pass** (hidden). **Placement: fail.** The running head (`PRIDE. and PREJUDICE`) is at x 152–278, y 7–21 pt, centred: the Dynamic Island's own footprint (about x 152–278, y 11–48 pt), so on the device the island covers it. The folio `page 7` is at y 911–925 pt, inside the 34 pt bottom safe area and on the home indicator (about y 919–924 pt). The first text line's ink is at y 59–75 pt, just below the island and level with the top safe-area edge (59 pt). | `iphone-04-epub-quiet.png`, `iphone-04-epub-quiet-annotated.png` |
| 3 | Tap the middle third: toolbar and bottom bar over the page, status bar back; does the page move or re-paginate? | **Pass.** The status bar, toolbar and bottom bar appeared as overlays. The safe area stayed 59 / 34 pt, the stage stayed 430 × 932, the selection surface stayed (0, 28, 430 × 875) and the folio stayed `page 7`. In the screenshots every pixel row from y 114.7 to 833 pt is identical before and after: the page did not move or re-paginate. The Android window resize does not happen on iOS. | `iphone-05-epub-chrome-shown.png` |
| 4 | Tap the page: chrome and status bar hide; same page? | **Pass.** The chrome and status bar hid. The screenshot is pixel-identical to the screenshot before the chrome was shown. | `iphone-06-epub-chrome-hidden.png` |
| 5 | Right third forward, left third back, right-to-left swipe forward | **Pass.** Page 7 → 8 → 7, then the swipe went 7 → 8. The chrome stayed hidden throughout. | `iphone-07…09` |
| 6 | Show chrome, drag the toolbar up: hides | **Pass.** | `iphone-10-epub-toolbar-dragged-up.png` |
| 7 | Display (Aa): Progress Percent, Off, Page | **Pass.** The folio read `1%`, then nothing, then `page 8`. The panel is a bottom sheet over the page; Progress sits under Text size and Line spacing. | `iphone-11-epub-display-panel.png`, `iphone-12…14` |
| 8 | Multi-page PDF: place in muted ink under the page; tap zones; does the chrome move the page? | **Pass, with the same placement problem.** `page 1 of 15` is in muted ink under the page at y 906–920 pt, which is again inside the bottom safe area, over the home indicator. The right third went 1 → 2 and the left third went 2 → 1. Showing the chrome did not move the page: only the status bar, toolbar and bottom-bar rows differ. | `iphone-15…18`, `iphone-15-pdf-quiet-annotated.png` |
| 9 | neko.epub: the left third turns forward; the hint does not show again | **Pass.** No hint. The left third went 1 → 2 → 3 and the right third went 3 → 2. The running head `一` also sits under the island (x 209–221, y 7–21 pt). | `iphone-19…21` |
| 10 | Back to the library through the revealed toolbar; the library shows the status bar | **Pass.** | `iphone-22-library-end.png` |

Notes:

- `iphone-15-pdf-quiet.png` had a personal notification banner over the top of
  the page. I blanked it out before committing; the PDF page below it is untouched.
- The display-panel screenshot shows the sheet scrolled so that Progress is
  visible; the test scrolled it with `ensureVisible`.

## iPad Air 5: not verified

None of the checkpoints ran on the iPad. Two things on the device blocked it,
and I did not change either one:

1. **No free storage.** Installing the profile build over the existing app
   failed with `Insufficient storage` (`TotalDiskSpaceRequired = 100218801`,
   about 100 MB). The debug test build failed the same way: flutter reported
   `Could not run build/ios/iphoneos/Runner.app`, and on the second attempt the
   Dart VM service never appeared. I deleted nothing on the iPad to make room.
2. **A system prompt.** For the whole session (about 2.5 h, still there at
   16:58 PDT) the iPad sat on the home screen in **landscape**, showing a
   modal "Touch ID for 'iCloud Storage'" prompt. It needs a person to answer it.

The iPad still has the Shōsai build it had before this session. The checks
that matter most there are whether hiding the status bar changes the safe
area (an iPad without a notch normally reports a 24 pt top inset only while
the status bar shows) and where the head and folio sit. To run them, free
about 200 MB, dismiss the prompt, unlock the iPad and run the same test
again (steps below).

## What the code does (why the head and folio collide)

- `ReaderScreen` (`lib/reader/view.dart`, around line 708) lays out its body with
  `SafeArea(top: false, bottom: false)`, so the reading stage is the full screen
  (stage rect 0, 0, 430 × 932 on the iPhone).
- `_ReaderPageFurniture` (`lib/reader/view_stage.dart`, around lines 519–580)
  places the running head and the folio in fixed 28 pt rows at the top and
  bottom of that stage, without adding `MediaQuery.paddingOf(context)` or
  `viewPadding`. On a phone with a Dynamic Island or notch, and with a home
  indicator, both rows end up under hardware or system UI. On iOS the safe area
  does not shrink when the status bar is hidden: it stayed 59 / 34 pt while
  the status bar was hidden and while it was shown.
- On iOS the reader hides the status bar with
  `SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: [])`,
  which also lets the home indicator auto-hide. iOS does not resize the
  Flutter view for this, which is why the page does not jump on iOS while it
  does on Android (where `ReaderSystemBars.kt` changes the window).

## State left on the devices

- **iPhone:** a profile build of `main` (7ddfda8; the only changes are the build
  settings above, and no test assets) installed over the app, then launched; it
  shows the library. Installing over the app kept its data container (the
  database dates from 2026-10-29). The real library was already empty before
  this session, so add a book to try the quiet page by hand. The test's books
  and settings were only in the app's `tmp/` folder.
- **iPad:** unchanged. The install failed (above).

## What could not be automated

- The Dynamic Island and the home indicator are hardware and system overlays
  and do not appear in device screenshots. Their outlines in the `*-annotated`
  images are approximate (island about 126 × 37 pt, 11 pt from the top;
  indicator about 144 × 5 pt, 8 pt above the bottom). The safe-area bands are
  exact (from `MediaQuery`).
- The test taps through Flutter's gesture system (`WidgetTester`), not through
  the iOS touch screen, so system edge gestures (home swipe on the folio row,
  Control Centre from the top edge) were not exercised.
- Whether the home indicator actually auto-hid while the page was quiet is not
  visible in screenshots.

## Re-running

`quiet_page_ios_test.dart.txt` is the test, and `iphone-run-qp.log` holds every
`QP` and `SHOT` line from the iPhone run. To run it again, copy the test to
`integration_test/quiet_page_ios_test.dart`. Put the four books in `qp-books/`
and list that folder under `flutter: assets:` in `pubspec.yaml`. Apply the build
workarounds above, then run:
`flutter drive --driver=integration_test/driver.dart --target=integration_test/quiet_page_ios_test.dart -d <udid> --dart-define=QP_DEVICE=ipad --keep-app-running`.
Pipe the output through a watcher that runs
`pymobiledevice3 developer dvt screenshot --udid <udid> --userspace <label>.png`
for each `SHOT <label>` line.
