# Sidebar transition measurements

Compared baseline `b38bfe9` with the initial page-card implementation, before the
final sidebar background-color, divider, and outline adjustments, using Release builds,
Xcode 27, one iPhone 16 Pro simulator running iOS 27, and the same invented completed chat.
Both builds used the identical compiler-only extraction documented in
[README.md](README.md).

## Findings

The repeatable improvement is **9.8% fewer app CPU instructions** per open/close
cycle. App CPU time was lower in all three candidate runs, but the baseline
varied substantially; the first pair's 44% reduction is not a reliable general
speedup estimate. Memory use was effectively unchanged. The later automated
round-trip times were also essentially unchanged.

| Metric | Before | After | Interpretation |
| --- | ---: | ---: | --- |
| CPU time per open/close cycle, range of run means | 344–571 ms | 313–318 ms | Lower in each run; exact reduction is environment-sensitive |
| CPU instructions per cycle, all-sample mean | 2,319.64 million | 2,091.39 million | 9.8% less app CPU work |
| Peak physical memory per measured block, mean ± SD | 78.04 ± 0.67 MB | 77.45 ± 0.70 MB | No meaningful memory win established |
| Automated round trip per cycle, runs 2–3 | 1,422 ms | 1,412 ms | Approximately unchanged; includes automation overhead |
| Opening spring response / damping | 0.32 s / 0.86 | 0.32 s / 0.86 | Unchanged |
| Closing spring response / damping | 0.28 s / 0.90 | 0.28 s / 0.90 | Unchanged |

Spring response is a configuration parameter, not a measured settling time.
Neither animation definition was edited. The implementation removes the
sidebar-driven blur/dimming and moves the page over a stationary sidebar.
This comparison measures those changes together, not the individual effect of
each modifier. No additional production optimization/shim was added based on
these results.

## Method and complete run means

Execution order: before 1, after 1, after 2, before 2, after 3, before 3.
Each run launches a fresh app process, opens the same fixture, scrolls to the
same position, and settles before measurement. Each measured block contains two
open/close cycles. XCTest discards one warm-up block and retains eight blocks
per run: **24 measured blocks / 48 cycles per variant**, or 192 measured
opening/closing transitions overall. CPU/memory measurements target the app,
not the UI test runner. No video recording or profiling ran during these tests.

| Build / run | CPU per cycle (ms) | Instructions per cycle (million) | Peak physical memory (MB) | Automated round trip per cycle (ms) |
| --- | ---: | ---: | ---: | ---: |
| Before 1 | 570.87 | 2,307.24 | 78.66 | 1,713.95 |
| After 1 | 317.64 | 2,093.27 | 76.83 | 1,408.94 |
| After 2 | 314.74 | 2,094.80 | 77.71 | 1,413.17 |
| Before 2 | 343.63 | 2,326.30 | 77.79 | 1,417.53 |
| After 3 | 313.46 | 2,086.10 | 77.80 | 1,410.37 |
| Before 3 | 388.90 | 2,325.37 | 77.67 | 1,427.03 |

All six benchmark tests passed. The first baseline run was substantially slower
despite similar instruction counts; its cause was not isolated. It is retained
above, not silently discarded. Individual blocks in one run are correlated;
these are descriptive measurements, not independent-device confidence bounds.

## Limits

- Simulator CPU time is not physical-device performance or total rendering cost.
  App metrics exclude GPU/render-server work and include app-side accessibility
  work caused by UI automation.
- Clock metrics include XCTest event delivery and idle waits. They are **not**
  touch-to-first-frame latency or animation duration.
- `XCTHitchMetric` returned no samples here. That is unavailable evidence, not
  zero hitches. No FPS, hitch-rate, or GPU improvement is claimed.
- Video capture is a separate visual demonstration. Both panes retain the same
  playback rate and are aligned at the first visible opening motion. A separately
  labeled quarter-speed version slows both panes equally. Neither establishes
  touch latency or device frame pacing. The simulator recordings were normalized
  to 60 Hz for reliable decoding, without motion interpolation; that export rate
  is not a measured app FPS. The real-time clip holds the final frame for 1.9
  seconds so the open states can be compared; the animation itself is not retimed.
- Fixtures, reports, and video content are freshly invented; no instance data,
  real conversations, or raw diagnostic logs belong in a published report.

## Reproduce

Use the fixture and isolated simulator setup in [README.md](README.md). Install
each Release build in turn and run only
`SidebarUITests/SidebarUITests/testSidebarPerformance`. Do not record the screen
at the same time. Run `testSidebarVideo` separately for light-mode visual capture
or `testDarkSidebarVideo` for the matching dark-mode comparison. The measurements
above were collected in light mode, not repeated in dark mode.

Export each result bundle with:

```sh
xcrun xcresulttool get test-results metrics --path before-results.xcresult > before.json
xcrun xcresulttool get test-results metrics --path after-results.xcresult > after.json
python3 summarize_metrics.py before=before.json after=after.json
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest test_metrics.py -v
```

The summary helper accepts repeated `before=`/`after=` inputs, checks units,
normalizes CPU/clock values to one cycle, and omits device metadata. Memory is
reported in decimal MB, without dividing by the number of cycles.
