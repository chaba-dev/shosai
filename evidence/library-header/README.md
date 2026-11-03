# Library header and Add books: proof of work for #279

Captured 2026-11-03 from branch `claude/project-thread-xo8iw2` (commit 20b0d3e0), a
debug build running in iOS 18.2 Simulators with `xcrun simctl io … screenshot` and
`recordVideo`. The real app (`lib/main.dart`) was driven by a throwaway integration
test; three fixture books (`fixtures/sample.epub`, `fixtures/sample.pdf`,
`fixtures/epub-layout/rich-chapter.epub`) were handed to it with
`xcrun simctl openurl` (the "Open in Shōsai" path).

- `iphone-ja-*`: iPhone 16 Pro, Japanese.
  - a: the one-row header (ライブラリ, 3冊, search, "+").
  - b, b2, b3: search opened, "Sample" typed, then キャンセル.
  - c, c2: the Add books sheet (ファイルを選択 / Dropbox を接続 / Google Drive を接続), then dismissed.
  - d: pull-to-refresh mid-pull.
  - `iphone-ja-search-and-add-books.mov`: search, type, cancel, "+", dismiss the sheet (15 s).
- `ipad-landscape-*`: iPad Pro 13-inch (M4), English, landscape.
  - e: the library (no Refresh or Add books in the header; Add books at the sidebar foot).
  - f: the Add books dialog.
  - g: Settings > Manage connections (no "Connect folder").
- `ipad-portrait-*`: the same three states in portrait.

Capture notes:
- Text entry went through the test's mocked text input, so no software keyboard appears.
- The cyan crosshair in `d` is the integration-test pointer marker for the held drag.
- To build with Xcode 27, the local build raised the iOS deployment target to 15.0. To
  force landscape, it limited the iPad's orientations to landscape. Neither change was committed.
