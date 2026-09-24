# Immediate streaming regression checks

All fixtures are newly invented. The tests do not access a server, account, chat
database, credentials, screenshots, or network service.

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
- 250 Markdown/view checks pass: original list and tilde-fence corruption
  reproduced; each incremental input matches a full parse; unchanged chunk
  objects are reused; ordinary fences keep the same parent; preview IDs and
  native text-view lifetimes survive completion.
- Off-main parse plus chunk preparation, median of 20 optimized runs:
  approximately 0.03 ms at 1k characters, 0.22 ms at 10k, and 2.08 ms at 103k.
  These are component measurements, not iPhone frame rates or time-to-pixel.

The new path reparses the changing prose document correctly, then reuses unchanged
render chunks. It is not a claim of a new incremental Markdown syntax parser.
Completed reasoning/tool prefixes are separately cached, and superseded queued
work is skipped without adding a debounce or reveal delay.

## Required iOS verification before release

- Build and run the full app with synthetic Socket.IO responses.
- Record slow/bursty streams and long reasoning-to-answer transitions.
- Check lists, both fence types, links, math, images, HTML/SVG/chart/Mermaid
  previews, Python blocks, and answers longer than 8k characters.
- Exercise stop, immediate completion, regenerate/continue, chat switching,
  scrolling away from the bottom, and expanding/collapsing thinking.
- Inspect video for disappearing text, completion jumps and view recreation.
- Profile actual UIKit layout, CPU, memory and update latency.
- Verify code syntax highlighting and math after completion.

Full-app iOS build/video verification has not yet been completed for this patch.
ThreadSanitizer coverage is also not established. Do not treat component results
as release sign-off.
