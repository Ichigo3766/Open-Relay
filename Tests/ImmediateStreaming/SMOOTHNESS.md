# Typewriter streaming validation

This records the preceding iteration. See [EFFICIENCY.md](EFFICIENCY.md) for the
subsequent optimization pass, additional worst cases and current measurements.

The accepted local implementation is candidate 9. Candidate 10's additional
prefix cache was tested and removed: its CPU benefit was inconsistent. All data
is freshly invented; no real instance, account or chat was used. Nothing has been
uploaded. Raw recordings, logs and Xcode results remain outside version control.

Base: upstream `b38bfe91ab0d584c7ab22ac119adadae1af3dbf5`, fetched and rebased
again before final validation. The comparison below is against the earlier local
typewriter prototype **`400fa36`, not upstream main**. Both use Release builds,
the same pinned dependencies and an isolated iOS 27 simulator.

## Verified causes and changes

| Reproduction | Verified cause | Accepted change |
| --- | --- | --- |
| 20 characters every 500 ms reveal in bursts | A 90-character/s minimum empties each packet in about 220 ms | One shared adaptive clock estimates packet cadence, eases speed changes and holds its catch-up target until new input |
| Thinking jumps by whole packets and remounts | Thinking bypasses animation; identity changes with the first 80 characters | Use the shared clock and position-based identity within the append-ordered reasoning group |
| 100 KB thinking stops advancing | Repeated case-insensitive Swift string searches take longer than packet intervals; cancelled tasks still queue synchronous parser work | Use native-string presence checks, one active parse and only the newest pending cumulative input; publish completed intermediate parses during live structural input |
| Thinking appears only at completion | The socket handler explicitly ignores reasoning-text deltas | Accumulate structured items by ID/order and reconstruct using the existing history helper at delivery/read time |
| A late snapshot can erase subsequent tokens | Snapshots are deferred to MainActor while deltas apply immediately | Apply both in socket order; retain one pending UI notification |
| Completed history can replay unfinished thinking | Animation eligibility depends only on the stored reasoning marker | Pass the actual message streaming state; retain disclosure-owned progress across collapse/reopen |

There is no startup timer, fixed character reserve or transport holdback.
Markdown parsing is driven by input, not animation frames. Completed parsed
chunks are reused. The reveal clock stops when caught up, explicitly finished or
discarded. Reduce Motion and collapsed thinking catch up immediately. Genuine
network outages still pause; the first packet's rate must be estimated.

The additional production changes over `400fa36` touch three files, net +118
lines. The complete local streaming branch removes about 1,097 production lines
relative to upstream, excluding tests. No dependency or server change is needed.

## Repeated measurements

Three quiet, unrecorded rounds alternate build order: earlier/current,
current/earlier, earlier/current. No simultaneous builds or media processing.
Cadence numbers are medians of each run's longest native text-progress gap in
the active input window, excluding its first second:

| Case | Earlier prototype | Current |
| --- | ---: | ---: |
| Regular answer | 317 ms | 83 ms |
| Irregular answer | 283 ms | 133 ms |
| Regular thinking | 500 ms | 67 ms |
| Irregular thinking | 517 ms | 133 ms |

Regular thinking's largest update falls from 21 characters to 2, and its native
view count falls from four to one. The earlier prototype fails all four regular
cadence/identity assertions. Both retain exact final text in these short cases.
The injected two-second network outage still produces about a 1.75-second visible
pause. Warmup-excluded results do not claim zero startup catch-up pause.

Process user+system CPU medians, not elapsed time or energy:

| Workload | Earlier prototype | Current |
| --- | ---: | ---: |
| Short prose | 426 ms | 435 ms |
| 107,643-character prose | 1,879 ms | 2,039 ms |
| 4,356-character code | 1,018 ms | 892 ms |
| Answer after settled 106 KB thinking | 316 ms | 313 ms |
| Warmed short responses, 18 samples/build | 448 ms | 447 ms |
| Live 100 KB thinking, 40 characters/100 ms | 4,220 ms; frozen, incomplete | 2,662 ms; advances, exact |
| Live 100 KB thinking, 40 characters/10 ms | 2,579 ms; frozen, incomplete | 1,964 ms; advances, exact |

The large-thinking CPU comparison is **not equal completed work**: the earlier
build still lacks the appended text after a further one-second drain. The fast
case advances through a median 35 intermediate native lengths in the current
build; the earlier build has one length throughout. Callback FPS alone misses
that failure. An isolated 100 KB structural parse falls from about 200–216 ms to
about 37–39 ms, without changing parser semantics.

Smoother animation is not free: regular slow answer/thinking CPU rises from
799/692 ms to 973/1,237 ms as visible updates become much more frequent. Ordinary
large prose also costs about 8.5% more, while code costs about 12.3% less and warmed
short prose is effectively unchanged. These results do not establish universally
lower CPU, zero scheduling stalls or physical-device energy savings.

All 63 repeated current-build workloads pass: 24 cadence cases, 12 pipeline
cases, six large-thinking cases, three fast-thinking cases and 18 warm responses.

## Video verification

Both native captures use the same test source and packet schedule. Their visible
`Packet 1` transition, independent of text reveal, aligns the exports within one
60 Hz sample. First displayed text is deliberately not the alignment cue.
Four matched cases cover regular/irregular answers and thinking. Normal-speed
and explicitly labelled quarter-speed versions use identical cropping/scaling;
quarter speed holds the same frames four times longer, without interpolation.

Sequential video-frame differences independently check five-second body-only
windows, excluding the clock, packet counter and blinking cursor:

| Region | Changed frames, earlier → current | Longest unchanged gap, earlier → current |
| --- | ---: | ---: |
| Regular answer | 118/299 → 167/299 | 317 → 67 ms |
| Regular thinking | 10/299 → 167/299 | 517 → 83 ms |

Separate actual-app captures exercise live thinking-to-answer handoff, lists,
code fences, Unicode, math, long prose, disclosure interactions and navigation.
Those complicated examples are current-build demonstrations, not matched A/B
timing comparisons. All display only fixture text and generic app chrome.

Use sequential FFmpeg decoding for inspection: random AVFoundation image seeking
occasionally produced garbled glyphs absent from sequential frames. Captures are
normalized before sampling; unchanged samples may be duplicated, never invented
by motion interpolation. Videos are qualitative evidence, not CPU benchmarks.
Exports strip audio and metadata and remain local pending review/publication
approval. See also the capture procedure in [Native/README.md](Native/README.md).
The privacy review includes all 1,788 normal-comparison frames and 1,980 actual-app
frames sampled at 60 Hz, using OCR plus source/visual review. Corresponding
quarter-speed picture frames match the normal export apart from small encoding
differences (minimum PSNR 49.6 dB across 1,788 comparisons).

## Correctness and interaction coverage

- 421 core checks pass, including structured thinking/answer deltas, snapshots
  between deltas, authoritative corrections, absent optional indices, multiple
  content parts, tool-separated thinking, continuation, empty/non-renderable
  snapshots, legacy delivery, invalid indices and concurrent producers.
- 20 repeated core runs pass (8,420 assertions); ThreadSanitizer passes the same
  421 checks without a reported race.
- 2,255 Markdown/view checks pass: incremental input versus full parse,
  formatting, Unicode graphemes, chunk reuse, reveal pacing, large bursts, final
  equality, view/clock lifetime and Reduce Motion.
- Twelve selected native regression methods pass: real formatting/layout,
  syntax highlighting, math/previews, ten blank-answer trials, Unicode/mixed-case
  reasoning tags, completed-history behavior, structural replacement/remount,
  fast and large thinking, final-content and character-progress checks.
- Both fixture test methods pass across six modes and two simulated emission
  overheads, checking exact delta/final equality and absolute deadlines.
- Seven successful full-app UI scenarios total about 11.8 minutes including
  setup: all six content modes, slow thinking/answer handoff, three disclosure
  cycles, completed long-thinking expansion/collapse, three stop/restart cycles,
  five up/down scroll pairs plus six chat switches, and three complex replays.

The UI helper initially failed navigation because XCUITest marked a visible
floating toolbar non-hittable on a restored long chat. It now allows the matched
button's measured on-screen center, then asserts the old assistant row disappears
before typing. A separate run stalled in repeated 60-second XCTest animation-idle
waits before input; the idle app had negligible CPU. That run was interrupted,
and the unchanged scenario passed in a fresh runner. Neither incomplete run is
counted as a passing test or a streaming-latency measurement.

## Rejected iterations and protected edge cases

| Experiment or regression | Evidence and resolution |
| --- | --- |
| Recompute catch-up rate from shrinking remainder every frame | Creates an exponential tail; hold the target until new input instead |
| Carry initial burst speed into the next packet | Deterministic regression fails; reset to measured arrival speed when caught up |
| Faster searches without bounding parse work | 10 ms arrivals still freeze; bound the worker and latest pending input |
| Publish only for a nil separate tail | Real frozen-prefix form has an empty tail; accept both empty forms, retain complete-presentation fallback for a nonempty tail |
| Keep reveal state inside a conditional text label | Collapse/reopen can replay; own state in disclosure instead |
| Fixture final payload longer than emitted deltas | New equality check fails; emit all invented content and test protocol deadlines |
| Additional unchanged-prefix cache (candidate 10) | Native correctness and capture pass, but three matched CPU rounds are mixed; removed in favor of simpler candidate 9 |

The discarded cache's warmed per-round CPU medians were 462→442, 472→383 and
448→482 ms. Across other workloads it also alternated wins and regressions;
overlapping ranges did not justify more invalidation/lifetime state. Its
cache-only tests were removed with the experiment; final core/component checks
were rerun against the restored accepted source.

## Limits

Simulator native-text callbacks and captured pixels are not physical-device GPU
or photon-level measurements. Physical-device energy, older-runtime coverage and
real-world network variability remain unverified. The available older-runtime
test build was blocked by an unchanged dependency/toolchain ABI mismatch in both
builds; it is not counted as passing. Line wrapping may move an unfinished word.
No pacing policy can animate unavailable text without earlier buffering.

Protocol reference: public upstream
[response event handling](https://github.com/open-webui/open-webui/blob/main/backend/open_webui/utils/middleware.py).
