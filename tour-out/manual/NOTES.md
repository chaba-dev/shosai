# Shōsai release readiness: Mac, iPhone and iPad evidence

Run on Darwin's Mac on 2026-10-23, from /tmp worktrees of
`origin/claude/project-thread-z0ckw5-tour`. Darwin's checkout was not touched.
Hosts and devices:

- macOS 26.6.2 (arm64) with Flutter 3.41.5 from Nix (macOS builds via
  `scripts/build-flutter-macos.sh`) and the pinned official SDK for iOS.
- iPhone 15 Pro Max on iOS 26.6.2, with the system language set to Japanese.
- iPad Air (5th generation) on iPadOS 26.6.2, with the system language set
  to English.
- iPhone SE (3rd generation) simulator on iOS 18.2.

## Folder map

| Folder | What |
| --- | --- |
| `macos/` | Tour c1720ac6, default 800x600 @2: exit 0, 221 s, no FAILED steps |
| `macos-small/` | Tour 8aafba9, 1024x768 @2: exit 0, 217 s, no FAILED steps |
| `macos-tall/` | Tour 8aafba9, 1280x1600 @1: exit 0, 213 s, no FAILED steps |
| `macos-phone/` | Tour c1720ac6, 390x844 @2, stopped by me after the note step (screenshots only) |
| `iphone-ja/` | iPhone, tour c1720ac6, Japanese UI: exit 0, 249 s |
| `iphone-014ca72/` | iPhone, tour 014ca72a, still Japanese (stale install bundle, see below) |
| `iphone-e8e6ef2/` | iPhone, tour e8e6ef20, English: exit 0, 266 s |
| `iphone/` | iPhone, tour b165ed3e (latest), plus the failed attempts `attempt*` |
| `ipad/` | First iPad attempt: signing failure (profile without the iPad, "No Accounts") |
| `ipad-run/` | iPad, tour e8e6ef20: exit 0, 300 s |
| `iphone-se-simulator/` | Simulator, tour e8e6ef20 (debug): exit 0 |
| `videos/` | Screen recordings (H.264 mp4) |
| `manual/` | Checks by hand on a release build, with these notes |
| `app-name/` | PR #219 (Shōsai / Shōsai Dev) checks |

Each run folder holds `exit.txt`, the TOUR lines (`run.log` or
`tour-lines.txt`), `report.json` and the screenshots. For devices, the
screenshots are decoded from the driver's `shots` map.

## Tour results

### macOS

- **Tour 8aafba9 at the default 800x600:** exit 0, 110 s. Every step from `pdf`
  onward failed: `pdf-FAILED: Bad state: no "attention" on screen`, then
  `gibbon`, `neko`, `search` and `notes-place` with `no way to the library`.
  These were harness problems, fixed in c1720ac6: the library row wasn't built
  in the small window, and the wide sidebar has no "Library" tooltip. That
  run's output was replaced by the c1720ac6 run in `macos/`.
- **Tour c1720ac6 at 800x600:** no failures. origin-note-typed true,
  origin-note-listed true, relaunch-reading true.
- **1024x768 and 1280x1600:** no failures. relaunch-reading true.

### iPhone 15 Pro Max

- **c1720ac6:** 7 FAILED steps (`origin-highlight`, `origin-notes`,
  `origin-display`, `pdf-display`, `pdf-highlight`, `search`, `notes-place`).
  Each one looks for an English label while the app is in Japanese. The
  screenshots show the Japanese UI working: `07-origin-selection.png` is the
  selection menu (黄/緑/青/ピンク/紫), `09-origin-page-note-editor.png` is
  the #213 page-note dialog with 保存/キャンセル visible, and
  `22-relaunch.png` shows four open books after relaunch.
- **014ca72a:** still Japanese, with the same failures. Root cause:
  `flutter drive` installs `build/ios/iphoneos/Runner.app`. Right after that
  run, that bundle still held the 11:50 build from the c1720ac6 run, while
  `Profile-iphoneos/` held the new one. The Xcode step reported "up to date"
  and didn't refresh `iphoneos/`, so the old tour, without the locale
  override, ran.
- **e8e6ef20:** `locale: en system ja_JP`. The only failure is
  `search-FAILED: Bad state: no "Tour page note" on screen`.
  origin-note-typed false, origin-note-listed false. relaunch-reading true.
- **b165ed3e:** exit 0, 264 s. The installed bundle was compiled at 13:08:55
  on this commit. `locale: en system ja_JP`,
  `origin-note-fields: 1 in all, 1 in the dialog`, origin-note-typed **false**,
  origin-note-listed **false**. The only failure is
  `search-FAILED: Bad state: no "Tour page note" on screen`.
  relaunch-reading true.
- **Earlier b165ed3e attempts** (kept in `iphone/attempt4*` and `attempt5*`):
  - **Attempt 4:** the install failed, because my simulator build had left a
    simulator-platform `objective_c.framework` in the shared
    `build/native_assets/ios`, and the device rejected its signature.
  - **Attempt 5:** after I cleared the build folders, flutter built the app
    but couldn't find `build/ios/iphoneos/Runner.app`. It only copies the
    bundle there when that folder already exists.

### iPad Air

- **e8e6ef20:** `locale: en system en_US`, 1180x820 @2. The only failure is
  `search-FAILED: Bad state: no "Tour page note" on screen`.
  origin-note-typed false, origin-note-listed false. relaunch-reading true.
  Everything else passed: highlight, display, PDF, PDF highlight, PDF link,
  Gibbon footnote, neko, notes place, open books and relaunch.
- **Note dialog:** it renders correctly on the iPad (`ipad-run/10-origin-page-note-editor.png`),
  but the typed text never reached the field, so Save stored nothing and the
  panel lists only the highlight (`11-origin-notes-panel.png`).

### iPhone SE simulator (375x667)

- **e8e6ef20:** origin-note-typed **true**, origin-note-listed **true**.
  `origin-highlight` and `pdf-highlight` FAILED with no "Yellow" or "Green":
  the drag didn't bring up the selection menu on the simulator.
  relaunch-reading true.

## Recordings (`videos/`)

| File | What it shows |
| --- | --- |
| `pr214-keys.mp4` (37 s) | macOS release build. Opens Gibbon from the library and, without clicking the page, presses Right, Right, Space, Left. Each one moves the page. Then opens the PDF and presses PageDown twice. Location lines: 2% ch1 → 3% ch2 → 3% ch2 (next spread) → 5% ch3 → 3% ch2; PDF page 1 → pages 2–3 → pages 4–5. Stills in `manual/keys-*.png` and `manual/keys-location-lines.png`. |
| `pr215-relaunch.mp4` (29 s) | Three books open (Origin, Gibbon, the PDF). The clip is cut around Cmd+Q so what is behind the window is never recorded. After relaunch, the reader is back on the last book (the PDF at pages 4–5) with all three books in the rail, and the Notes place shows "Reading now 3". The window was back 0.36 s after `open`. |
| `pr213-note-dialog-iphone-se-simulator.mp4` (40 s) | Phone width (375 pt) on the iPhone SE simulator, recorded with `xcrun simctl io recordVideo` while the tour drove the app. Notes sheet, Page note dialog with Save and Cancel visible, "Tour page note" typed, Save, and the note listed in the panel. |

Not recorded, and why:

- **#213 in a narrowed macOS window.** AeroSpace tiles every window to full
  screen here, and I couldn't float the window without reconfiguring
  AeroSpace. The macOS tour at 390x844 renders only "Test starting..." in the
  real window, so recording it showed nothing. The simulator clip replaces it.
  The tour screenshots `macos-phone/10-origin-page-note-editor.png` and
  `11-origin-notes-panel.png` show the dialog and the saved note at 390 pt on
  macOS.
- **Real iPhone or iPad screen.** AVFoundation capture of the device
  (`kCMIOHardwarePropertyAllowScreenCaptureDevices`) fails with "Cannot
  Record", because this process has no camera permission. `devicectl` has no
  screenshot command, and `idevicescreenshot` isn't installed. Device
  screenshots are the tour's in-app captures.

## Checks by hand (macOS release build)

The release build used bundle id `dev.shosai.shosai-flutter.tourcheck`, so it
had its own empty data folder. Books were imported through Add books →
Choose a folder → /tmp/tour-books → Import.

1. **Arrow keys and Space before clicking (#214): works.** In both books, every
   key turned the page with no click on the page first. **Bug:** Left from the
   first spread of a chapter goes to the *first* spread of the previous
   chapter, not its last spread. Seen in Origin (Introduction → start of
   chapter 2, skipping the contents spread) and in Gibbon (5% ch3 → 3% ch2,
   skipping the spread between). Compare `keys-3-after-right.png` with
   `keys-5-after-left.png`.
2. **Relaunch (#215): works.** All open books came back in the rail and in
   "Reading now", and the reader reopened on the last book at the same
   spread. Reopening Origin landed at 16%, chapter 3.
   **Minor:** the percentages in "Reading now" and the library hero lag the
   reader (Origin 11% vs 14–16%, Gibbon 2% vs 3%).
3. **PDF Night: not applied.** With Night selected in the panel, the PDF page
   stays white and the chrome stays light (`pdf-night-selected-page-stays-white.png`).
   On an EPUB, Night darkens the page but leaves the chrome light
   (`macos-small/13-origin-night-larger.png`).
4. **Rail Library button from the reader does nothing.** A real mouse click
   on the rail's Library icon shows the "Library" tooltip but stays in the
   reader (`rail-library-click-stays-in-reader.png`). The Notes icon next to
   it navigates fine.
5. **Visual issues:**
   - **PDF citation link:** tapping [13], which targets page 10, doesn't
     navigate. The location stays at pages 2–3 and no back pill appears, in
     every macOS run and on the iPad, although the step reports ok.
   - **PDF zoom:** at 200% the PDF page is clipped at the right edge
     (`macos-small/17-pdf-night-zoomed.png`).
   - **Library shadow:** a shadow band is drawn across the library under the
     book grid (`import-done.png`, `library-hero-after-first-open.png`).
   - **Focus frame:** after keyboard paging, a thin frame is drawn around the
     EPUB text block. It's likely the focus indicator.
   - **Neko:** the vertical Japanese text renders well (`macos-small/24-neko-turned.png`).
6. **Timings (rough):**

   | Action | Time |
   | --- | --- |
   | Cold launch to window | about 1 s |
   | Relaunch to window | 0.36 s, with the restored reader already drawn in the first recorded frame |
   | Import of 5 books (managed copy) | about 4 s |
   | EPUB and PDF opens | each drew in under the 2.5–4 s I waited |

   No blank pages, apart from an empty right-hand page at the end of short
   chapters.

## PR #219 app name (`app-name/`)

- **macOS debug:** the menu bar reads "Shōsai Dev" (`macos-debug-menubar.png`),
  and the About box reads "Shōsai Dev, Version 0.1.0 (1)"
  (`macos-debug-about.png`).
- **macOS release:** CFBundleName and CFBundleDisplayName are "Shōsai"
  (`macos-info-plist.txt`).
- **iOS profile:** CFBundleDisplayName is "Shōsai Dev" (`ios-profile-info-plist.txt`).
  It was installed over the tour app in place on the iPhone, with no
  uninstall, and `devicectl device info apps` lists "Shōsai Dev"
  (`iphone-devicectl-apps.txt`). The last tour run put the tour build back,
  so I then reinstalled the #219 build in place. The iPhone now runs
  "Shōsai Dev", with origin.epub and attention.pdf copied into its Documents
  folder. The Info.plist sets neither UIFileSharingEnabled nor
  LSSupportsOpeningDocumentsInPlace, so Files doesn't show that folder.

## Device app handling

The app was never uninstalled on purpose. `flutter drive` uninstalls in its
stop step unless it gets `--keep-app-running`:

- Before Darwin flagged this, the c1720ac6 iPhone run ended with that
  uninstall.
- In the 014ca72a run I stopped flutter_tools after the report was written,
  before its uninstall step.
- Every later run used `--keep-app-running`.

The app is still installed on both the iPhone and the iPad.
