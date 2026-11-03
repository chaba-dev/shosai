# Covers of unopened EPUBs: proof of work

Captured on 2026-11-03 on a Mac with Xcode 27. "Before" is `origin/main` (aaddef96).
"After" is `claude/project-thread-xo8iw2` (8b63715c). For the iOS build, both had #285
(the iOS 15 minimum) stacked locally; it is not part of the covers branch.

The shelf is one connection with nine unopened files: seven EPUBs with cover images, one
EPUB without one (`scan_0042_final.epub`) and one PDF. The file names are deliberately
unhelpful (`pg1342-images-3.epub`) so you can see where the title comes from. Nothing
had been opened, so every card is an unopened source file.

| | Before (main) | After (branch) |
| --- | --- | --- |
| iPhone 16 Pro shelf | `iphone-1-before-shelf.png` | `iphone-2-after-shelf.png` |
| Search "Austen" | `iphone-3-before-search-austen.png` (no match) | `iphone-4-after-search-austen.png` (found by the EPUB's author) |
| iPhone video: launch, shelf, search, cancel | `iphone-before-launch-and-search.mov` | `iphone-after-launch-and-search.mov` |
| Desktop shelf, 1280×800 | `desktop-1-before-shelf.png` | `desktop-2-after-shelf.png` |

What the "after" captures show:
- The shelf loads first with generated covers. Each EPUB's own cover, title and author
  then replace them as its preview lands, without blocking the shelf (see the video).
- The EPUB without a cover keeps a generated cover, now with its real title and author
  ("Notes on a Quiet Library", A. Reader).
- The PDF keeps its file name and a generated cover. PDF previews come later.
- Search matches a previewed author.

How they were captured (read before relying on them):
- **The source is a test folder connection, not Dropbox or Google Drive.** No storage
  account was available on this Mac. For the iPhone, a local-only build turned on
  folder sources (normally desktop-only) and connected a folder of generated demo
  books on the host. The preview pass reads it through the same `LibraryLocation`
  ranged-read interface that Dropbox and Google Drive implement. The unit tests cover
  ranged reads, including a large book whose 8 MiB chapter is never fetched. Network
  latency is not simulated here, so on a real account covers land more slowly.
- The iPhone captures come from a throwaway integration test that drives the real app,
  with `xcrun simctl io` screenshots and `recordVideo` taken on the host. The test
  supplies the typed text, so no software keyboard appears.
- The Mac's screen was locked, so the desktop shots are the production shell rendered
  at 1280×800 (2×) in a Flutter test with the real core and the same folder, not
  screenshots of the macOS app.
