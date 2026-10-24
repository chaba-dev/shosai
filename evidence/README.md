# Evidence: safe-area sidebar/rail and shelf-edge removal

Not for merge. Proof for `claude/project-thread-9d0qvj`: `before` is `main`
(ed96773) and `after` is the fix branch (f305264).

## Real iPad Air (5th generation), iPadOS 26.6.2

`ipad-*-{before,after}.png` are device screenshots that include the iOS status
bar, taken headless with `pymobiledevice3 developer dvt screenshot --userspace`.
A throwaway driver entrypoint (never committed) forced each orientation with
`SystemChrome.setPreferredOrientations` and opened the book through its library
card. For this capture only, the build had `UIRequiresFullScreen` set because
iPadOS ignores forced orientation without it.

- `landscape-left-library`, `portrait-library`, `landscape-right-library`: the
  sidebar mark and "Shōsai" sit under the clock in `before` and below the status
  bar in `after`. In `before`, the shadowed shelf-edge band shows under the
  covers in portrait; `after` has no band.
- `landscape-right-reader`, `portrait-reader`, `landscape-left-reader`: the 書
  mark at the top of the rail overlaps the clock in `before` and clears it in
  `after`. The reader shows "The book file is missing" because the iPad's PDF
  had already been deleted when a build was installed over the app (see the
  report).
- `ipad-final-release-build-after.png`: the normal `after` release build, now
  installed on the iPad.

## iPhone 15 Pro Max simulator, iOS 17.5

`iphone-sim-*-{before,after}.png` come from `xcrun simctl io screenshot`, with
the landscape captures rotated upright. The library was seeded with
`fixtures/sample.epub`.

- `landscape-right-*`: the Dynamic Island is on the sidebar/rail side. In
  `before` it covers "Bookmarks"/"Search" and the rail icons; in `after` the
  sidebar and rail grow by the inset and everything clears it.
- `landscape-left-*`: the island is on the content side. In `after` the
  sidebar also takes the left inset, because iOS reports both landscape insets.
- `portrait-*`: the bottom-navigation layout, the same in both.

## iPad Air 11-inch (M2) simulator, iOS 18.2, videos

`ipad-air-11-sim-video-{before,after}.mp4` (about 31 s each) show the library in
landscape, then portrait, then landscape again; the book opens and the reader's
rail appears in landscape, then portrait, then landscape. They are recorded
with `simctl io recordVideo`, and each landscape section is turned upright with
AVFoundation, because simctl records the portrait framebuffer.
