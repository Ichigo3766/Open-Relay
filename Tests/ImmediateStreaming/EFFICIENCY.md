# Streaming efficiency follow-up

Comparison: local `da0bc73` versus this change, both based on upstream
`b38bfe91ab0d584c7ab22ac119adadae1af3dbf5`. This is **not** a comparison against
upstream's original renderer. Release builds use the same pinned packages and
an isolated iOS 27 simulator. Every input and test account is newly invented;
no real instance, private chat, credential, or user recording is used.

## Small changes retained

- Count each parsed reasoning string once. Reveal by trimming its short remaining
  tail instead of walking from its beginning on every animation frame. String
  operations remain grapheme-safe; there is no extra cached copy of the text.
- Observe character progress in a small text-only view. Keep clock ownership in
  the parent so collapsing/reopening does not replay text, but do not invalidate
  the disclosure/header for every revealed character.
- Bootstrap the arrival-rate average over its first few samples. Restart an idle
  clock with the newly learned rate. A deterministic late-first-layout fixture
  improves its longest post-warmup progress gap from 13 to 9 frames at 60 Hz
  (217 to 150 ms). The existing ordinary-cadence limits are unchanged.
- Share duplicated reasoning-tag conversion. Preserve both passes and their
  ordering: exact output parity holds across 11,457 synthetic inputs, including
  nested, incomplete, mixed-case, Unicode and repeated tags. A simpler one-pass
  experiment changed nested-input semantics and was rejected.

These changes remove 48 production lines overall, excluding tests. They add no
transport holdback, debounce, startup timer, character reserve, dependency change,
or server change. There is no claim that the consolidation itself saves CPU.

## Repeated native measurements

Three unrecorded pairs alternate order: baseline/candidate, candidate/baseline,
baseline/candidate. No concurrent build, profiler, recording or media conversion.
Normal host services remain active. CPU is process user+system time from
`getrusage`, not elapsed time, GPU cost, energy, or a physical-device measurement.

| Workload | Baseline CPU | Candidate CPU |
| --- | ---: | ---: |
| Regular live thinking | 805 ms | 681 ms |
| Irregular live thinking | 632 ms | 495 ms |
| Regular live answer | 722 ms | 1,147 ms |
| 100 KB live thinking through parser and view | 2,740 ms | 2,647 ms |
| Same-size paragraph-separated thinking, view only | 1,252 ms | 1,238 ms |
| 100 KB multilingual thinking, view only | 2,822 ms | 2,977 ms |
| 100 KB single paragraph, view only | 3,763 ms | 3,736 ms |
| Short prose pipeline | 332 ms | 349 ms |
| 107,643-character prose pipeline | 1,855 ms | 1,903 ms |
| Code pipeline | 850 ms | 850 ms |
| Answer after settled thinking | 235 ms | 226 ms |

These are medians, not guarantees. Regular/irregular thinking use about 15%/22%
less CPU in this sample; the long-thinking path improves about 3.4%. The data do
**not** establish universally lower CPU or lower memory. Regular-answer CPU is
higher and variable (baseline 647–883 ms, candidate 755–1,208 ms); it is not
omitted merely because its smoothness checks pass.
Footprint varies with allocator/cache history. For example, large-prose sampled
peak medians are 54.31/53.61 MiB, while the Unicode test has inconsistent starting
and ending footprints. Those deltas alone do not establish a leak or a saving.

| Native cadence metric | Baseline | Candidate |
| --- | ---: | ---: |
| Regular answer: longest progress gap | 83 ms | 67 ms |
| Regular thinking: longest progress gap | 83 ms | 83 ms |
| Irregular answer: longest progress gap | 133 ms | 117 ms |
| Irregular thinking: longest progress gap | 150 ms | 133 ms |
| Regular answer: first text at display callback | 46 ms | 57 ms |
| Regular thinking: first text at display callback | 83 ms | 63 ms |
| 100 KB full thinking: callback p95 | 19.5 ms | 18.9 ms |

Progress-gap medians exclude the first second and intentionally injected network
outages. Ordinary cadence callback p95 remains about 16.7 ms, consistent with
60 Hz scheduling; this is not proof that every frame was presented on time.
All three final candidate repeats pass the unchanged cadence assertions. One
baseline repeat fails: cold first thinking text takes 589 ms, with a later
450 ms progress gap. In an earlier candidate without the text-only view, a 700 ms
display-callback gap produced a 717 ms text-progress gap and a 37-character step.
An input callback was also late. The same build's other two repeats passed.
Both scheduling outliers are retained, not attributed conclusively to a
particular host process. The final table includes the failing baseline repeat.

All repeated cases preserved final text; thinking retained one native view.
The full matrix contains 108 workloads across both builds. Exact final content
does not by itself prove smooth intermediate delivery.

To investigate the short-answer CPU result, the eight cadence cases were then
repeated three times per build **without relaunching the test process**. All six
iterations (48 workloads) pass, using the same unchanged assertions. Regular
answer CPU is tied: median 983 ms baseline versus 985 ms candidate; irregular
answer is 867 versus 866 ms. Regular thinking is 1,110 versus 966 ms, and irregular
thinking is 888 versus 629 ms. Already character-paced answer input is 1,107
versus 1,189 ms. Cost still varies within a process, so first-use setup alone does
not explain it. These diagnostic repeats weaken the case for a consistent
short-answer regression but do not establish universally lower CPU. The original
three-pair results above are retained rather than replaced with this later run.

Reproduce this diagnostic with `testTypewriterCadence`, `-test-iterations 3` and
`-test-repetition-relaunch-enabled NO`, serially for each build without recording.

## Whole-app CPU and idle cost

Three additional unrecorded A/B pairs exercise the real socket, chat view,
thinking-to-answer handoff and final snapshot. A read-only external process
monitor samples every 100 ms; phase-boundary uncertainty is at most 45 ms.
`proc_pid_rusage` counters are converted from Mach ticks with `mach_timebase_info`
and cross-checked against `getrusage` (54.395 versus 54.391 ms).

| Phase | Baseline CPU, median (range) | Candidate CPU, median (range) |
| --- | ---: | ---: |
| About 10 s thinking | 2,606 ms (2,454–2,837) | 2,814 ms (2,409–2,817) |
| About 5 s answer | 1,258 ms (1,010–1,342) | 1,076 ms (1,027–1,233) |

The ranges overlap; these results do not prove a whole-app CPU reduction. Earlier
comparisons and an ablation restoring the old pacing also varied, so the pacing
change is retained for its deterministic recovery improvement, not a CPU claim.
Sampled peak footprints are approximately 71–75 MiB in both builds. There is no
established memory reduction. After completion, a separate 21.225-second idle
sample uses 14.117 ms CPU (0.067% of one core) and footprint changes from 74.940
to 74.971 MiB. This supports stopping the animation clock, not a universal
absence-of-leaks claim. No energy or physical-device FPS was measured.

## Remaining layout limit and rejected alternatives

100 KB **without paragraph breaks** remains a real worst case: callback p95 is
about 733 ms and progress gaps reach 750 ms in both builds. Multilingual 100 KB
thinking reaches roughly 50–67 ms callback p95.
Separate stack sampling points to Core Text framesetter/layout work, rather
than the typewriter clock, as a major cost. Sampled runs are not timing results.

An exploratory same-input, 30-update native layout comparison tested
non-scrolling TextKit 1 and 2 text views, with both full replacement and
append-only text-storage edits. Selection/accessibility stay enabled:

| Content shape | Existing label CPU | TextKit 1 replace / append | TextKit 2 replace / append |
| --- | ---: | ---: | ---: |
| Paragraph-separated | 413 ms | 4,445 / 3,171 ms | 13,206 / 10,026 ms |
| Single paragraph | 13,361 ms | 3,407 / 2,534 ms | 3,083 / 2,968 ms |
| Multilingual paragraphs | 1,490 ms | 14,146 / 10,191 ms | 24,907 / 18,710 ms |

This single exploratory pass is not the typewriter benchmark above. Although
the alternatives help the single paragraph, they regress common shapes severely,
add memory, and change measured height. No renderer swap, hybrid selection
rule, artificial line break, truncated accessibility text, or text-selection
change is retained. A deeper incremental-layout design would need its own
correctness and performance evidence; this change does not claim to solve it.

## Video

The full-app replay sends live reasoning deltas, then answer deltas, then a final
structured snapshot. Screens and sequentially decoded frames confirm thinking
before completion, character-sized progression, a stable disclosure, and the
answer remaining visible at completion. The fixture deliberately pauses input
for two seconds at `Replay ready`; the application adds no such pause.

The locally retained 19-second normal-speed export and its labelled-by-filename
quarter-speed counterpart show the same frames without interpolation. The
assistant region is cropped identically throughout; setup, status bar, user
bubble, audio and source metadata are omitted. A contact sheet covers the whole
export. No recording, raw log or Xcode result bundle is added to version control.

A six-second thinking-body window, starting two seconds after the first visible
status dot in each capture, changes on 194/359 baseline and 193/359 final-candidate
sampled 60 Hz frames. Longest unchanged gaps are 100 ms in both. This supports
preserved smooth visible progress, **not** a dramatic visual improvement over
the prior typewriter.

## Reproduce the focused checks

    bash Tests/ImmediateStreaming/run.sh
    MARKDOWN_VIEW_SOURCE=/path/to/MarkdownView CMARK_SOURCE=/path/to/swift-cmark \
      bash Tests/ImmediateStreaming/run-renderer.sh
    bash Tests/ImmediateStreaming/run-reasoning.sh
    RELAY_REASONING_REF=da0bc73 bash Tests/ImmediateStreaming/run-reasoning.sh --dump > before.jsonl
    bash Tests/ImmediateStreaming/run-reasoning.sh --dump > after.jsonl
    cmp before.jsonl after.jsonl

The focused suites pass 421 core, 2,256 rendering and 767 reasoning assertions.
The final Release build also passes 12 native correctness tests and six recorded
full-app UI tests: thinking-to-answer handoff, scrolling with six chat switches,
three stop/restart cycles, six content formats, three live disclosure cycles,
and completed-thinking expansion/collapse. Fast 10 ms packet tests require
intermediate visible progress as well as exact final text. Existing native
cadence thresholds were not relaxed. Both synthetic replay/scheduling unit tests
also pass.
See [Native/README.md](Native/README.md) for the synthetic native/UI harness.
`testPlainThinkingLayoutAlternatives` is exploratory evidence, not production
code or a replacement for real-app interaction testing.
