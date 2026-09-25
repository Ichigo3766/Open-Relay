# Cached-block typewriter prototype

Historical results for the first typewriter prototype (`400fa36`). The current
pacing and reasoning iteration is documented in [SMOOTHNESS.md](SMOOTHNESS.md);
the measurements below must not be relabeled as that later candidate's results.

This local prototype keeps the character reveal effect. It builds on the stable
streaming renderer, not the original paced raw-Markdown pipeline. No dependency
implementation or server is changed.

## Mechanism

- Server updates drive Markdown parsing and special-content detection. Animation
  frames do not feed text back through either parser.
- The reveal controller keeps parsed chunks and their character counts. Completed
  chunks retain their render objects. Only the current partial chunk gets a new
  formatted prefix; it still requires native text layout as it grows.
- Prefixes preserve nested formatting and count Swift Characters (grapheme
  clusters), not UTF-16 units. Tables, equations and image attachments are atomic.
- A display link reveals at least 90 characters/second, accelerating to catch up
  approximately 250 ms after the latest parsed snapshot. There is no fixed
  character reserve. This is not identical timing to the old reveal policy.
- The clock is invalidated when caught up, removed from the screen, or released.
  Reduce Motion and initially completed messages bypass animation. Completion
  can finish an existing reveal; authoritative source replacements show the
  replacement without replaying stale characters.

The prototype animates formatted text prefixes, not a GPU-only glyph mask. It
does not reserve a large invisible message area or replace the text renderer.
Network stalls may still leave a pause after all available text has appeared.

## Validation

The component suite checks every reveal budget in freshly invented prose,
headings, nested lists, quotes, formatting, links, code, Unicode and atomic nodes.
It also checks final AST equality, retained chunk identity, completion, source
replacement, Reduce Motion, clock restart/shutdown and controller release.

The native suite checks actual UIKit text passing through multiple character
prefixes, then the existing rendering/identity/math/preview regressions. The
full-pipeline benchmark uses the same scheduled cumulative snapshots in both
implementations, with the typewriter enabled in each. CPU is process user+system
time, including finalization. Callback gaps are CADisplayLink scheduling gaps,
not physical-device GPU FPS. Memory is sampled process physical footprint, not
allocation counts or a guaranteed peak; cases share a process and caches.

Baseline: Open Relay `b38bfe91ab0d584c7ab22ac119adadae1af3dbf5`, plus the same
compiler-only compatibility adjustments used in the earlier native benchmark.
The candidate adds this prototype to `6e34a99`. Both use Release optimization,
Xcode 27 / iOS 27 simulator, and the same pinned dependencies. Test runs are
serial, without compilation or recording during timing. Fixtures are invented;
no real instance, account, chat, credential or user content is used.

The earlier numbers in BENCHMARKS.md describe the **animation-free** candidate,
not this prototype. They must not be presented as this prototype's results.

## Native results

Three alternating A/B rounds, with typewriter animation enabled in both builds:

| Fixture | CPU, original → prototype | p95 callback gap, original → prototype |
| --- | ---: | ---: |
| Short prose, first case after app launch | 334 → 468 ms | 16.7 → 16.7 ms |
| 107,643-character prose | 31,643 → 1,870 ms | 142.9 → 19.3 ms |
| 4,356-character Swift code | 3,018 → 994 ms | 17.2 → 16.8 ms |
| Answer after a 106 KB settled reasoning prefix | 735 → 334 ms | 16.7 → 16.7 ms |

The large-prose case had 169–183 callback gaps over 50 ms per original run,
versus zero in all three prototype runs. Code still had one such gap in two
prototype runs (one in each original run); this is not a zero-jank claim.

The startup-adjacent short-prose results vary substantially: 262–712 ms for the
prototype versus 262–362 ms originally. An additional test waits three seconds
after startup and runs six distinct short responses per build. All pass, with
median CPU **648 → 546 ms** (about 16% less). Those responses include an extra
trial label and are a separate workload. The warmed test does not erase the
startup-adjacent regression or establish a universal short-message improvement.

Both implementations receive identical text and delivery deadlines; their
reveal policies differ. In particular, the old implementation's capped drain
continues long after the large input ends. The prototype's faster catch-up is
part of its reduced total work. These numbers do not isolate renderer efficiency
at identical reveal speed. The reasoning-prefix case measures the pipeline and
answer renderer; the known settled prefix is removed using UTF-8 offsets before
rendering in both builds, not repeatedly parsed as part of the answer.

Memory is not uniformly lower. Median sampled process footprint maxima were:

| Fixture | Original → prototype |
| --- | ---: |
| Short prose | 30.2 → 30.5 MiB |
| Large prose | 43.9 → 48.6 MiB |
| Code | 86.7 → 79.0 MiB |
| Reasoning-prefix answer | 81.2 → 72.8 MiB |

Process caches carry between cases; these are not isolated per-message allocation
measurements, physical-device memory limits, or energy measurements.

## Correctness results

- Release app build succeeds; 1,832 component checks and 401 pipeline/store checks
  pass. The synthetic HTTP fixture has two passing protocol/scheduling tests.
- Native UIKit sampling observes successive character prefixes from length 1
  through 26, including after the server-completion flag changes. The final text
  is exact. It does not jump directly to the entire 26-character input.
- Nine native formatting/large-content cases retain exact parsed content, stable
  view identities and zero completion-height change. Code retains its native
  view and real final syntax highlighting. The code view stays in streaming mode
  until the reveal finishes, avoiding repeated finalization during those frames.
- Two equations render as math; text survives HTML, SVG, Mermaid and Python
  preview completion. All ten final-reasoning trials retain the answer.
- All 24 cases in the repeated pipeline/renderer comparison and all 12 warmed
  short-message trials pass final-content assertions.
- Full-app cancellation followed by a new response passes all three cycles.
  Expanding and collapsing a long completed thinking block passes, returning to
  its original height. Synthetic slow, mixed-formatting and long video replays
  complete successfully.

Initial test-harness mistakes were corrected and rerun: plain-text assertions
must account for the native paragraph terminator and Markdown's trailing-space
normalization. The first reasoning benchmark incorrectly reparsed/displayed the
entire settled reasoning instead of isolating its live answer. Those failed runs
are not counted in the results above. No production workaround was added for
these harness mistakes.

The first scrolling/chat-switching run missed its active-stream assertion after
XCUITest repeatedly waited 60 seconds for animation-idle notifications. The
fixture finished during that wait. That run is a failure, not a performance
measurement. The unchanged isolated retry passes: five up/down gesture pairs
during a live response, completion, then six alternating chat switches with
additional scrolling. No production code or assertions were changed for the
retry. The automation-idle failure remains recorded rather than counted as a
passing trial.

## Local visual evidence

The prose recording shows partial words growing character by character. The
mixed-formatting recording shows ordered lists, a code fence, Unicode and math.
Completed text remains visible. Ordinary word wrapping still moves a growing
word to the next line; this prototype does not pre-layout invisible future text.

Local exports use native simulator decoding, constant 30 fps, cropping/scaling,
and no audio or source metadata. The quarter-speed prose replay holds the same
frames four times longer, with no motion interpolation. Contact sheets, native
frame comparisons and OCR of every exported normal-speed frame were reviewed;
only freshly invented fixture content and generic app chrome appear. No media
or raw Xcode diagnostics are committed or uploaded.

Physical-device GPU, energy, and older-runtime testing remain outstanding, as in
the earlier native report. This prototype changes one production file (174 net
added lines); the full local streaming changes still remove 1,215 production
lines overall relative to the tested upstream baseline.
