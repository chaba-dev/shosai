# Continuous EPUB long-chapter scroll — 2026-10-22

Frame times and memory while scrolling one long chapter in continuous mode,
with the lazily laid-out window (`flutter/lib/reader/epub/continuous.dart`).

- Date: 2026-10-22
- Fixture: `longChapterEpub()` (`flutter/test/support/epub_navigation_fixture.dart`),
  one chapter of 302,562 canonical scalars in 2,404 top-level nodes
  (alternating short and long paragraphs). That is above the largest real
  chapter in the 2026-10-02 corpus pass (220,454 scalars).
- Viewport: 1280×800 logical, device pixel ratio 1, 18 px type, line height 1.5.
  The chapter column is about 104,000 px tall.
- Host: Amp orb, linux x64, Xvfb with Mesa software EGL. The Linux embedder
  composited nothing in this environment, so raster times read as zero; the
  build times are the Dart UI-thread cost and are the meaningful figure here.
- Build: `--profile`, Flutter 3.41.5 / Dart 3.11.3 (Nix-provided via `.agents/dev`).

## Run

From `flutter/`, on a desktop host with a display:

```sh
flutter drive --profile -d linux \
  --driver=integration_test/driver.dart \
  --target=integration_test/epub_continuous_long_chapter_test.dart
```

Set `SHOSAI_MEASURE_OUT` to also write the JSON result to a file. The test
scrolls with one 400 px wheel event per frame (24,000 px/s at 60 Hz) to a
quarter, the half, the end and back to the half, then settles for 30 frames
at each checkpoint.

## Results

| Measure | p50 | p95 | p99 | max |
|---|---:|---:|---:|---:|
| Frame build (ms), 3,376 frames | 0.10 | 1.28 | 1.68 | 5.33 |
| Window step (ms), 406 steps | 3.76 | 6.21 | 11.58 | 18.39 |

No frame exceeded 16.7 ms. A window step runs in a post-frame callback, so its
time is spent between frames. Under the frame timing of this host it did not
push a frame past budget, but the step maximum is about one frame, so a slower
device would be the first place to look.

| Checkpoint | Window (nodes) | Retained paragraphs | Dart heap | RSS |
|---|---|---:|---:|---:|
| Open | 0–51 | 51 | 24.8 MB | 254 MB |
| Quarter | 599–679 | 80 | 29.1 MB | 266 MB |
| Half | 1235–1315 | 80 | 29.2 MB | 268 MB |
| End | 2356–2403 | 47 | 25.3 MB | 284 MB |
| Back to half | 1170–1242 | 72 | 28.6 MB | 279 MB |

The window stays under about 100 nodes (one viewport plus its lead and the
retained margin) wherever the reader is, and the Dart heap stays flat. RSS
grows by about 25–30 MB over the run while the retained paragraphs stay
bounded, and fell on the way back. RSS includes engine, raster and font caches
and was not attributed further, so it is not a measurement of retained layout;
a longer soak would show whether it levels.

For comparison, under the whole-chapter design of #162 (without its ceilings),
a similar 238,000-scalar chapter took about 230 ms of batched layout and then
about 0.9 s on one frame to build its single selection surface of 472,000
endpoints. That was a scratch measurement in a `flutter test` VM on the same
host, at a 632 px content width.
