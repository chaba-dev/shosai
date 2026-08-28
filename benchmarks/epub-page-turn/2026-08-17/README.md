# EPUB page-turn benchmark — 2026-08-17

- Date: 2026-08-17
- Purpose: Plan 001 native-renderer baseline
- Measurement: synthetic app-action-to-compositor-present latency

The app harness starts timing when Iced delivers a navigation or font-size
action and finishes when the subscription result for the resulting redraw is
processed. In Iced 0.14's Winit runner, that redraw event is broadcast after
draw and directly before `compositor.present`; its subscription message is
processed after the current event-loop callback.

The metric covers application input dispatch, state and pagination work, Iced
layout and draw, and compositor presentation. It does not include the OS input
event before Iced dispatch, physical display scan-out, or panel response time.

## Run the protocol

From the repository root:

```sh
./benchmarks/epub-page-turn/2026-08-17/run.sh 50
```

The runner builds `--release`, generates redistribution-safe large text and
image EPUBs under `target/`, and writes timestamped raw logs under
`target/epub-perf-results/`. It fixes the viewport at 700×700 (588 px reader,
single page) and 1000×700 (888 px reader, spread), waits 60 frames for window
stabilization, discards five operation warmups, then records 50 samples.

The generated books contain 16 chapters so one run can select stable
within-chapter and chapter-boundary pairs. Generated archives are byte-stable.
The runner fails if a run reports an error, never produces pages, omits one of
the 15 summaries, records a different sample count, or exceeds an operation's
p50 or p95 budget below.

## Initial budgets

| Operation | p50 budget | p95 budget |
|---|---:|---:|
| Warm page turn | ≤ 8 ms | ≤ 16.7 ms |
| Chapter transition | ≤ 16.7 ms | ≤ 33.3 ms |
| Font-size relayout | ≤ 50 ms | ≤ 100 ms |

## Baseline host

- MacBook Pro Mac16,5
- Apple M4 Max
- 48 GB memory
- macOS 26.5.2
- rustc 1.94.0

## Results

All values are milliseconds.

| Fixture | Mode | Operation | p50 | p95 |
|---|---|---|---:|---:|
| `sample.epub` | Single | Chapter transition | 0.581 | 1.618 |
| `sample.epub` | Single | Relayout | 0.432 | 0.662 |
| `sample.epub` | Spread | Relayout | 0.366 | 0.598 |
| Generated large text | Single | Warm page turn | 1.603 | 2.906 |
| Generated large text | Single | Chapter transition | 1.370 | 3.465 |
| Generated large text | Single | Relayout | 18.018 | 20.671 |
| Generated large text | Spread | Warm page turn | 2.813 | 6.306 |
| Generated large text | Spread | Chapter transition | 1.835 | 3.435 |
| Generated large text | Spread | Relayout | 22.485 | 25.588 |
| Generated large image | Single | Warm page turn | 0.337 | 1.196 |
| Generated large image | Single | Chapter transition | 0.587 | 1.683 |
| Generated large image | Single | Relayout | 1.341 | 2.944 |
| Generated large image | Spread | Warm page turn | 0.581 | 1.258 |
| Generated large image | Spread | Chapter transition | 0.846 | 2.204 |
| Generated large image | Spread | Relayout | 1.223 | 2.010 |

The small checked-in fixture has no within-chapter warm pair, and its two
chapters can share one spread, so those cells are intentionally omitted.
Large-text relayout is the dominant native cost but remains within the initial
budget. These numbers are a renderer-comparison baseline, not a universal
guarantee. Repeat the same protocol on released platforms and under
representative power and display conditions.
