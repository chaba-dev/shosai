# First-page covers of unopened PDFs: proof of work

Captured on 2026-11-03 on an iPhone 16 Pro simulator (iOS 18.2, Xcode 27). "Before" is
`claude/project-thread-xo8iw2` (8b63715c, #286, EPUB previews only). "After" is
`claude/project-thread-xo8iw2-pdf` (fd6c725c). For the iOS build, both had #285 (the
iOS 15 minimum) stacked locally; it is in neither PR's diff.

The shelf is one connection with seven unopened files and no books opened:

| File | Size | What it is |
| --- | --- | --- |
| `scan_20240117.pdf` | 1 KB | "Field Notes on Moss", Ada Okafor |
| `Document (3).pdf` | 1 KB | "Quarterly Garden Report", Ines Varga |
| `download.pdf` | 1 KB | "The Lighthouse Keeper's Log", Tomas Reyes |
| `IMG_0042.pdf` | 18 MB | "A Short Atlas of Rivers": a light first page, then 40 heavy pages |
| `heavy-scan-final-v2.pdf` | 6 MB | a single first page heavier than the 4 MiB preview cap |
| `pg1342-images-3.epub`, `pg2701-images.epub` | | EPUBs, previewed in both builds |

| | Before | After |
| --- | --- | --- |
| Shelf | `iphone-1-before-shelf.png` | `iphone-2-after-shelf.png` |
| Search "Okafor" | `iphone-3-before-search-okafor.png` (no match) | `iphone-4-after-search-okafor.png` (found by the PDF's Info author) |
| Video: launch, shelf, search, cancel | `iphone-before-launch-and-search.mov` | `iphone-after-launch-and-search.mov` |

What the "after" captures show:
- Each PDF's first page becomes its cover, and its Info title replaces the file name.
- The 18 MB `IMG_0042.pdf` is previewed from its first page without downloading the
  rest. The unit test with the same shape reads under 512 KB of a 6 MB file.
- `heavy-scan-final-v2.pdf` needs more than the cap to show its first page, so it
  keeps its file name and a generated cover. It is recorded as read and is not
  fetched again while unchanged.
- Search matches a PDF's author.

How they were captured:
- **The source is a test folder connection, not Dropbox or Google Drive.** No storage
  account is available on this Mac. A local-only build turned on folder sources for
  iOS and connected a host folder of generated files. Previews read it through the
  same `LibraryLocation` ranged-read interface that Dropbox and Google Drive
  implement, through the same 64 KiB block cache and 4 MiB cap. There is no network
  latency here.
- A throwaway integration test drives the real app, and `xcrun simctl io` takes the
  screenshots and video on the host. The test supplies the typed text, so no software
  keyboard appears.
