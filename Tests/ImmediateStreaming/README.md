# Immediate streaming regression checks

The current local branch additionally prototypes a character-by-character reveal
over parsed blocks. See [TYPEWRITER.md](TYPEWRITER.md). The transport pipeline is
still immediate; presentation animates independently without reparsing per frame.

All fixtures are newly invented. Component tests do not access a server, account,
chat database, credentials, screenshots, or network service. The optional native
UI suite uses only the bundled loopback fixture, never a real instance.

## Run

On an Apple Silicon Mac with a working Swift toolchain:

    bash Tests/ImmediateStreaming/run.sh

To reproduce the old behavior (expected failure):

    bash Tests/ImmediateStreaming/run.sh --baseline

The baseline is pinned to the tested base revision. RELAY_BASELINE_REF can
override it when investigating a different revision.

For Markdown and view-lifetime component tests, supply the dependency checkouts
matching the application's Package.resolved:

    MARKDOWN_VIEW_SOURCE=/path/to/MarkdownView \
    CMARK_SOURCE=/path/to/swift-cmark \
    bash Tests/ImmediateStreaming/run-renderer.sh

The renderer runner builds the real MarkdownParser and cmark sources, compiles the
real chunk splitter, and extracts the current Open Relay adapter and fence parser.
Only UIKit text rendering, the theme, and the finished-message cache are stubbed.
Native macOS SwiftUI/NSView probes check view lifetime. These tests do **not**
replace iOS UIKit layout, scrolling, syntax-highlighting, math-rendering, or video QA.

Optional compiler-only arguments can be passed through RELAY_SWIFT_FLAGS_FILE,
one argument per line. No dependency sources or SDK files are modified by the runners.

## Coverage and results

Base: Open Relay b38bfe91ab0d584c7ab22ac119adadae1af3dbf5.
MarkdownView: 2654e0d8254816bb9c1bdcbb73fa43bcc0f9f429.

- 401 core checks pass: immediate Unicode delivery, duplicate suppression,
  authoritative replacements, nested/quoted/incomplete structural markup,
  final-only responses, cancellation, session isolation, duplicate completion,
  consumer lifetime, concurrent token producers, and overload.
- Original-source checks reproduce delayed delivery and the accumulator's
  missed-update window; failure counts are assertions, not distinct bugs.
- 1,832 Markdown/view checks pass, including the original 253 checks: list and tilde-fence corruption
  reproduced; each incremental input matches a full parse; unchanged chunk
  objects are reused; ordinary fences keep the same parent; preview IDs and
  native text-view lifetimes survive completion.
- Typewriter checks cover every character budget, formatting, Unicode graphemes,
  final-content equality, cached objects, clock lifetime and Reduce Motion.

The new path reparses the changing prose document correctly, then reuses unchanged
render chunks. It is not a claim of a new incremental Markdown syntax parser.
Completed reasoning/tool prefixes are separately cached, and superseded queued
work is skipped without adding a debounce or reveal delay.

## Native verification and benchmarking

See [Native/README.md](Native/README.md) for the real-app XCTest/XCUITest harness
and [BENCHMARKS.md](BENCHMARKS.md) for matched before/after results and limitations.
The native tests exercise actual UIKit rendering, Markdown nodes, code-view
identity, final syntax highlighting, rendered equations, completion layout and
large reasoning blocks. The UI fixture supports slow and bursty responses,
cancellation, scrolling and chat switching without a production account.

The core suite also passed 20 consecutive repetitions (8,020 assertions) and two
ThreadSanitizer runs (401 checks each, no reported races). These checks supplement,
rather than replace, native rendering tests and physical-device validation.

For the pipeline-only optimized A/B benchmark:

    bash Tests/ImmediateStreaming/run-benchmark.sh --baseline
    bash Tests/ImmediateStreaming/run-benchmark.sh

It measures snapshot delivery and CPU, not network latency or displayed frames.
