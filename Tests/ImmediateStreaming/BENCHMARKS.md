# Immediate streaming: matched native measurements

## Method

Baseline: `b38bfe91ab0d584c7ab22ac119adadae1af3dbf5`.
Candidate: the immediate-streaming implementation plus the code-view lifetime
correction covered by these tests. Both use the same dependency lockfile
(MarkdownView `2654e0d8254816bb9c1bdcbb73fa43bcc0f9f429`).

Both complete apps were built with Xcode 27.0 / Swift 6.4, Release optimization,
and testability enabled, then run on the same isolated iOS 27.0 iPhone simulator.
Both received the identical compiler-only chat-body extraction and solver limits.
No dependency implementation was changed. Three serial, alternating A/B rounds
ran without simultaneous compilation or video recording. UI videos were recorded
separately. Fixtures are entirely invented; no production service/data was used.

## Latency

| Measurement | Original | Candidate | Interpretation |
| --- | ---: | ---: | --- |
| First word present in UIKit at a display callback; 20-character arrival every 500 ms | 1,612.7 ms | 24.1 ms | Median of 15 trials per build; about 1.59 seconds less client delay |
| Slow-stream final snapshot to pipeline idle | 482.0 ms | 0.134 ms | Median of 3; does not include asynchronous UIKit rendering |
| Fast-stream final snapshot to pipeline idle | 1,166.4 ms | 0.185 ms | Median of 3; removes the artificial reveal backlog |
| CPU for 100 updates after a 106,565-character closed reasoning prefix | 1,063.1 ms | 40.9 ms | Median of 3; about 96% less CPU |
| Same prefix: final snapshot to pipeline idle | 991.2 ms | 0.420 ms | Original still had 528–532 undisplayed characters; candidate had zero |

First-word samples ranged from 1,599.7–1,626.2 ms originally and 18.5–34.2 ms
afterward. This observes actual text in the real UIKit renderer, not merely the
pipeline callback. It is not a pixel/photon measurement or network benchmark.
It starts when the synthetic answer arrives, so it does not shorten model
generation, reasoning or network time. Text appears in arriving chunks; there is
no timer that manufactures character-by-character typing.

## Rendering cost and scheduling

Each fixture receives cumulative updates every 30 ms, with step size
`max(20, characterCount / 160)`. CPU is process user+system time while streaming.
The gap column is the median of each run's 95th-percentile CADisplayLink callback
interval. All values below are medians of three runs.

| Fixture | Characters | CPU, original → candidate | p95 callback gap, original → candidate |
| --- | ---: | ---: | ---: |
| Plain prose | 497 | 165.5 → 141.8 ms | 16.7 → 16.7 ms |
| Ordered list | 754 | 214.8 → 194.9 ms | 16.7 → 16.7 ms |
| Tilde-fenced Swift | 4,356 | 2,272.1 → 914.6 ms | 17.7 → 16.7 ms |
| Backtick-fenced Swift | 4,356 | 887.9 → 853.7 ms | 16.7 → 16.7 ms |
| Long prose | 15,372 | 2,148.6 → 1,143.7 ms | 24.2 → 17.7 ms |
| Large prose | 107,643 | 13,822.1 → 1,744.0 ms | 169.4 → 19.7 ms |
| One long paragraph | 21,300 | 4,741.0 → 1,305.2 ms | 58.9 → 18.1 ms |
| Long ordered list | 8,490 | 1,670.3 → 1,150.0 ms | 19.7 → 17.6 ms |
| Nested formatting / reference / Unicode | 114 | 56.9 → 54.6 ms | 33.3 → 17.2 ms |

Large prose had 72–83 callback gaps over 50 ms per original run versus zero in
all candidate runs. The single long paragraph had 24–26 versus zero. Small
fixtures do not show a material frame-pacing improvement. The short nested
fixture still had one isolated >50 ms gap in every candidate run (original:
1–4); idle simulator callback pacing can contribute. These are not measured GPU
frame drops, and the results do not establish a universal absence of judder.

## Correctness evidence

- All 27 candidate native renderer cases matched the real full-parser chunk
  nodes while streaming and after completion. Markdown view identities survived
  completion; both fence types retained one native CodeView through updates,
  and completed Swift code had real syntax-highlight attributes.
- Candidate completion height delta was zero in every renderer case. Original
  deltas included −1,176 points for large prose, −168 for long prose, +159 for
  one long paragraph and −12 for the short ordered list.
- Adding a large final reasoning block produced a sampled blank answer in 6/30
  original trials versus 0/30 candidate trials. Every trial ended with the answer
  present. This measures sampled visibility, not every possible interleaving.
- Native tests verified two rendered math equations and surrounding text through
  HTML, SVG, Mermaid and Python preview completion. This does not certify every
  preview's JavaScript behavior or external image loading.
- 401 core checks pass, including Unicode/replacements, final-only responses,
  duplicate completion, cancellation, session isolation, metadata, concurrent
  producers and overload. Twenty repeats passed 8,020 assertions; two additional
  ThreadSanitizer runs passed without a reported race.
- 253 component checks use the real Markdown parser/chunker. They reproduce the
  original list/tilde-fence errors, check incremental prefixes against full parses,
  and check stable chunks, preview IDs and view lifetimes.

The zero-height-change check holds Markdown content constant and changes only
the streaming flag. Newly supplied final metadata can still change layout: the
video shows a reasoning disclosure appearing when the fixture supplies that
block at completion. The answer remains present; this is not a claim to eliminate
all movement caused by new content.

The first native candidate run caught a genuine regression: the Markdown wrapper
recreated code views when assigning its theme, including at completion. The
correction routes parser-recognized code blocks through the existing CodeView
wrapper and removes cmark's synthetic terminal newline to preserve append-only
updates. The original candidate failed the code-view identity assertions;
the corrected implementation passed them in all three native rounds. No
third-party renderer patch was needed.

## Full-app interaction and video checks

The corrected candidate completed two five-scenario XCUITest runs covering
thinking-to-answer transitions, slow tokens, long code, mixed formatting and
long prose, with repeated up/down scrolling after each response. It also passed
six stop/restart cycles, two large thinking expansion/collapse tests, and a
133-second test that scrolls during a live response and switches six times
between a known long chat and a short chat. Every navigation required an assistant
message to be present. Expansion changed the fixture row from 244 to 20,632 points
and returned to 244 points on collapse.

Those passing candidate runs total about 13 minutes, including test setup. The
matching baseline streaming/cancellation/expansion runs took another six minutes.
Recorded synthetic slow-answer, code and completion sequences were reviewed,
including a 30-sample-per-second completion contact sheet. Video sampling is
qualitative evidence, not a claim about the simulator's true display refresh rate.

Initial navigation-harness runs failed because the live row's accessibility label
does not contain live-store text, and the mock server omitted the pinned-list and
title-update parts of the sidebar protocol. These fixture/selector problems were
corrected and the navigation scenario rerun successfully. They were not fixed by
weakening the native text assertions or changing app navigation code. Raw failed
runs are retained locally; they are not counted as passing tests.

## Why less code is sufficient

The production diff adds 392 lines and removes 1,781: **1,389 fewer lines**, not
counting tests. Most removed code managed reveal timers, rate estimation,
60-character holdback, drain coordination, guessed paragraph boundaries and a
separate streaming-only renderer. The replacement delivers complete snapshots,
keeps one renderer hierarchy and uses the established Markdown parser off-main.

The one-slot queue may replace an obsolete cumulative snapshot, never a raw
token delta or a tool/status event. Final snapshots are authoritative; generation
guards prevent old callbacks from ending a new response. Completed structural
prefixes and unchanged render chunks are reused. This is not a new incremental
Markdown syntax parser and is not simply deletion of safety checks.

## Limits

These results support lower client latency and better large-message rendering,
not a guarantee of zero bugs. Physical-device GPU/FPS, energy and memory profiling
remain outstanding. All timed native runs used iOS 27.0. The Xcode 27 testable
build could not launch on iOS 26.5 because the unchanged pinned swift-collections
dependency referenced `_swift_initBorrow`; both original and candidate exhibited
that toolchain/runtime incompatibility. No runtime or dependency workaround is
included. Older-runtime release validation still needs a compatible toolchain.

Raw Xcode logs, result bundles and synthetic videos remain local, outside version
control. They can contain host paths and must not be uploaded as-is.
