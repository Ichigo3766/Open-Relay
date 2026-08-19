import Foundation
import os.log

private let pipelineLog = Logger(subsystem: "com.openui", category: "StreamingPipeline")

// MARK: - Streaming Snapshot (main-thread readable output)

/// Immutable snapshot published to the main thread every drain tick.
/// All fields are pre-computed and pre-sliced by the background actor —
/// the main thread reads them without doing any O(N) string work.
struct StreamingSnapshot: Sendable {
    /// Content currently visible to the user (typewriter-drained). Full string.
    let displayContent: String

    // MARK: - Tool/reasoning split-render pre-slices
    //
    // When frozenBoundary > 0, the pipeline slices displayContent into
    // frozenContent + liveTail off-main so the view reads them directly.
    // Both are "" when frozenBoundary == 0.

    /// Effective frozen boundary offset (max of tool and reasoning offsets).
    let frozenBoundary: Int
    /// displayContent[..<frozenBoundary] — stable tool/reasoning HTML. Empty when frozenBoundary==0.
    let frozenContent: String
    /// displayContent[frozenBoundary...] — tiny live tail changing each tick. Empty when frozenBoundary==0.
    let liveTail: String

    // MARK: - Prose split-render pre-slices (post-tool path)
    //
    // When frozenProseBoundaryOffset > frozenBoundary, liveTail is further split.

    /// Relative prose boundary within liveTail: (frozenProseBoundaryOffset - frozenBoundary). 0 if N/A.
    let relProseBoundary: Int
    /// liveTail[..<relProseBoundary] — settled paragraphs inside the live tail. Empty when N/A.
    let liveTailFrozenProse: String
    /// liveTail[relProseBoundary...] — current in-progress paragraph. Empty when N/A.
    let liveTailLiveProse: String

    // MARK: - Pure-prose split-render pre-slices (no tool/reasoning blocks)
    //
    // When frozenBoundary==0 and frozenProseBoundaryOffset>0, split displayContent directly.

    /// displayContent[..<frozenProseBoundaryOffset] — settled paragraphs. Empty when N/A.
    let pureFrozenProse: String
    /// displayContent[frozenProseBoundaryOffset...] — current in-progress paragraph. Empty when N/A.
    let pureLiveProse: String

    // MARK: - Offsets (for diagnostics / liveTail has-special-content checks)
    let frozenToolBoundaryOffset: Int
    let frozenReasoningBoundaryOffset: Int
    let frozenProseBoundaryOffset: Int

    /// True while the pipeline is actively running (including finishing drain).
    let isActive: Bool

    static let idle = StreamingSnapshot(
        displayContent: "",
        frozenBoundary: 0,
        frozenContent: "",
        liveTail: "",
        relProseBoundary: 0,
        liveTailFrozenProse: "",
        liveTailLiveProse: "",
        pureFrozenProse: "",
        pureLiveProse: "",
        frozenToolBoundaryOffset: 0,
        frozenReasoningBoundaryOffset: 0,
        frozenProseBoundaryOffset: 0,
        isActive: false
    )
}

// MARK: - StreamingPipeline Actor

/// Background actor that owns the streaming buffer, drain timer, and all
/// O(N) string analysis. The main thread **never** touches the raw string —
/// it only reads the pre-built `StreamingSnapshot` published here.
///
/// ## Threading model
/// - `append(_:)` / `finish()` / `abort()` — called from `@MainActor` callers
///   via `Task { await pipeline.xxx() }`, always off the main thread inside the actor.
/// - Internal drain timer fires on a dedicated background serial queue.
/// - `publishSnapshot()` hops to `@MainActor` to write the snapshot.
actor StreamingPipeline {

    // MARK: - Callback

    /// Called on `@MainActor` with every new snapshot.
    private let onSnapshot: @MainActor (StreamingSnapshot) -> Void

    init(onSnapshot: @escaping @MainActor (StreamingSnapshot) -> Void) {
        self.onSnapshot = onSnapshot
    }

    // MARK: - Buffer

    /// The full accumulated server content (ground truth, append-only).
    private var buffer: String = ""

    // MARK: - Display cursor

    /// How many characters of `buffer` have been revealed to the user.
    private var displayedCount: Int = 0

    // MARK: - Drain state

    private var drainAccumulator: Double = 0
    private var isFinishing: Bool = false

    // MARK: - Dynamic drain constants
    //
    // The typewriter reveals content so that displayed text lags behind the server
    // buffer by ~dynamicLatencyFrames. This adapts to model speed each tick:
    //
    //   • Slow model (few chars/frame arriving): higher latency → smooth trickle
    //   • Fast model (many chars/frame arriving): lower latency → near-instant reveal
    //
    // Because MarkdownView only receives the short live tail (not the full string),
    // there is no longer any rendering concern at high reveal rates. The goal is
    // simply to keep the typewriter effect perceptible while not making the user
    // wait for content that is already fully available on the server.

    /// Target drain latency in frames. At 60 Hz ≈ 133 ms of lag.
    /// Keeps a short but perceptible typewriter effect on fast models.
    private let targetLatencyFrames: Double = 8

    /// Shorter latency used once the server has finished sending.
    /// Drains any remaining buffer quickly so the user isn't waiting.
    private let finishingLatencyFrames: Double = 6

    /// Minimum chars/frame floor — raised from 0.3 to 1.5 so brief server pauses
    /// don't crater the reveal rate to near-zero.  At 60 Hz, 1.5 chars/frame = 90
    /// chars/sec — enough to keep a smooth visible trickle across a 100ms gap.
    private let minRatePerFrame: Double = 1.5

    /// Maximum chars/frame cap — 15 chars/frame × 60 Hz = 900 chars/sec,
    /// enough to reveal a fast model's output without visible lag.
    private let maxRatePerFrame: Double = 15.0

    /// Perceptual keep-back: reserve chars so the drain never fully empties the
    /// buffer mid-stream (avoids the "catch-up then pause" stutter when the server
    /// briefly stalls). Raised from 2 → 8 to absorb a ~50ms pause at 150 chars/sec.
    /// Disabled when isFinishing (we want to drain to zero).
    private let tailReserve: Int = 8

    // MARK: - EMA smoothing for drain rate

    /// Exponential moving average of `currentBuffered`, used to smooth the drain rate
    /// across brief server pauses. Without EMA, a single tick where buffered drops to
    /// near-zero craters the rate to minRatePerFrame and causes visible stutter.
    ///
    /// α = 0.25: strong smoothing (75% of rate comes from history, 25% from this tick).
    private let emaAlpha: Double = 0.25
    /// Running EMA of buffered char count. Initialised to 0; warms up within ~4 frames.
    private var bufferedEMA: Double = 0

    // MARK: - Boundary cache (computed off-main, published via snapshot)

    private var frozenToolBoundaryOffset: Int = 0
    private var frozenReasoningBoundaryOffset: Int = 0
    private var frozenProseBoundaryOffset: Int = 0

    // MARK: - Stable-slice cache (preserves COW identity so downstream == is O(1))
    //
    // frozenContent / liveTailFrozenProse / pureFrozenProse only change when their
    // respective boundary offset advances. By storing the last computed String and
    // the offset it was built from, we hand the *same* String instance to the
    // snapshot when the boundary hasn't moved. Swift String == fast-paths to true
    // instantly when both sides share the same internal buffer (COW pointer equality),
    // so AssistantMessageContent.ParseCache skips its O(N) reparse on stable ticks.

    private var _cachedFrozenContent: (offset: Int, value: String) = (0, "")
    private var _cachedLiveTailFrozenProse: (offset: Int, value: String) = (0, "")
    private var _cachedPureFrozenProse: (offset: Int, value: String) = (0, "")

    // MARK: - Flags cache (keyed by buffer.utf8.count — O(1) after first calc)

    private struct ToolCallBlockFlags {
        let hasUnclosed: Bool
        let hasClosed: Bool
    }
    private var _toolCallFlagsCache: (contentCount: Int, flags: ToolCallBlockFlags)?
    /// Cached result of `hasOpenLivePreviewFence`, keyed by utf8.count.
    private var _livePreviewFenceCache: (contentCount: Int, hasOpen: Bool)?

    // MARK: - Drain timer

    private var drainTimer: DispatchSourceTimer?
    private static let timerQueue = DispatchQueue(
        label: "com.openui.StreamingPipeline.drain",
        qos: .userInteractive
    )

    // MARK: - Public interface (called from @MainActor)

    /// Begin a new streaming session. Resets all state and starts the drain timer.
    func begin() {
        resetState()
        startTimer()
    }

    /// Begin a streaming session for a **continue** response.
    ///
    /// Pre-seeds the buffer with `prefix` (the already-displayed content) and sets
    /// `displayedCount = prefix.count` so the typewriter drain cursor starts at the
    /// END of the existing content. Only new tokens appended beyond the prefix will
    /// be revealed — the old content is never re-streamed.
    func beginWithPrefix(_ prefix: String) {
        resetState()
        buffer = prefix
        displayedCount = prefix.count
        startTimer()
    }

    /// Append new server content. Content is always the full accumulated string.
    func append(_ content: String) {
        guard !isFinishing else { return }
        buffer = content
    }

    /// Signal that the server has finished sending tokens.
    /// The timer keeps running to drain the remaining buffer, then stops.
    func finish() {
        isFinishing = true
    }

    /// Immediately flush and stop. Used for abort / error paths.
    func abort() -> String {
        let result = buffer
        stopTimer()
        resetState()
        Task { @MainActor [onSnapshot] in onSnapshot(.idle) }
        return result
    }

    // MARK: - Internal reset

    private func resetState() {
        buffer = ""
        displayedCount = 0
        drainAccumulator = 0
        isFinishing = false
        bufferedEMA = 0
        frozenToolBoundaryOffset = 0
        frozenReasoningBoundaryOffset = 0
        frozenProseBoundaryOffset = 0
        _toolCallFlagsCache = nil
        _livePreviewFenceCache = nil
        _cachedFrozenContent = (0, "")
        _cachedLiveTailFrozenProse = (0, "")
        _cachedPureFrozenProse = (0, "")
    }

    // MARK: - Timer management

    private func startTimer() {
        stopTimer()
        let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
        // 60 Hz drain cadence — 16 ms interval. The scroll glide is handled by
        // .defaultScrollAnchor(.bottom) which pins sub-pixel continuously; the
        // drain timer only controls typewriter character reveal rate.
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.drainTick() }
        }
        timer.resume()
        drainTimer = timer
    }

    private func stopTimer() {
        drainTimer?.cancel()
        drainTimer = nil
    }

    // MARK: - Drain tick (runs inside actor isolation, off main thread)

    private func drainTick() {
        let full = buffer

        // Finish-exit: drain to zero when the server is done.
        if isFinishing && full.count == displayedCount {
            stopTimer()
            Task { @MainActor [onSnapshot] in onSnapshot(.idle) }
            return
        }

        // ── Tool call / reasoning freeze ──────────────────────────────────────
        // Hold the drain cursor while an unclosed tool_calls or reasoning block
        // is in-flight so the user never sees partial HTML. Fall through when
        // isFinishing so content isn't left invisible if the server closes abnormally.
        if toolCallFlags(for: full).hasUnclosed || reasoningFlags(for: full).hasUnclosed {
            if !isFinishing { return }
        }

        // ── Closed tool call fast-forward ─────────────────────────────────────
        if toolCallFlags(for: full).hasClosed {
            if let lastEnd = Self.lastToolCallDetailsEnd(in: full), displayedCount < lastEnd {
                let endIdx = full.index(full.startIndex, offsetBy: lastEnd)
                displayedCount = lastEnd
                frozenToolBoundaryOffset = lastEnd
                drainAccumulator = 0
                publishSnapshot(displayContent: String(full[..<endIdx]))
                return
            }
        }

        // ── Closed reasoning fast-forward ─────────────────────────────────────
        // Mirrors the tool_calls path: once a <details type="reasoning"> block
        // closes, instantly reveal everything up to and including it so the
        // ToolCallView renderer (not StreamingMarkdownView) shows it.
        if reasoningFlags(for: full).hasClosed {
            if let lastEnd = Self.lastReasoningDetailsEnd(in: full), displayedCount < lastEnd {
                let endIdx = full.index(full.startIndex, offsetBy: lastEnd)
                displayedCount = lastEnd
                frozenToolBoundaryOffset = max(frozenToolBoundaryOffset, lastEnd)
                drainAccumulator = 0
                publishSnapshot(displayContent: String(full[..<endIdx]))
                return
            }
        }

        // ── Target-latency drain ──────────────────────────────────────────────
        //
        // Drain formula: rate = buffered / targetLatencyFrames
        //
        // This keeps the typewriter ~133ms behind the server buffer on any model.
        // Fast models get a near-instant reveal; slow models get smooth trickle.
        // maxRatePerFrame prevents the drain from jumping too far in a single tick
        // on very large batches.
        //
        // Because MarkdownView only receives the short live tail (not the full
        // accumulated string), there is no rendering performance concern at high
        // reveal rates — the renderer handles the small delta cheaply.

        let fullCount = full.count   // O(N) — paid once, after all early-return branches
        let currentBuffered = fullCount - displayedCount

        // Keep-back: reserve a couple chars while streaming to prevent the cursor
        // catching up to zero and stalling when the server briefly pauses.
        let effectiveBuffered = isFinishing ? currentBuffered : max(0, currentBuffered - tailReserve)
        guard effectiveBuffered > 0 else { return }

        let latency = isFinishing ? finishingLatencyFrames : targetLatencyFrames

        // ── EMA-smoothed drain rate ───────────────────────────────────────────
        // Update the exponential moving average of buffered char count.
        // This smooths across brief server stalls: when the server pauses and
        // effectiveBuffered briefly drops to near-zero, the EMA stays elevated
        // (reflecting the recent healthy buffer depth), so baseRate stays above
        // minRatePerFrame and the reveal doesn't crater to a near-halt.
        // α = 0.25: 75% history + 25% this tick — strong but responsive smoothing.
        bufferedEMA = bufferedEMA * (1.0 - emaAlpha) + Double(effectiveBuffered) * emaAlpha
        let smoothedBuffered = isFinishing ? Double(effectiveBuffered) : max(Double(effectiveBuffered), bufferedEMA)
        let baseRate = smoothedBuffered / latency
        let charsThisFrame: Double

        // Live-preview code fences (html/svg/mermaid/chart) are rendered by a
        // WKWebView — fast-drain these so the WebView receives content quickly.
        if hasOpenLivePreviewFence(in: full) {
            charsThisFrame = max(baseRate, 500.0)
        } else {
            charsThisFrame = min(max(baseRate, minRatePerFrame), maxRatePerFrame)
        }

        drainAccumulator += charsThisFrame
        let reveal = min(Int(drainAccumulator), currentBuffered)
        guard reveal > 0 else { return }
        drainAccumulator -= Double(reveal)

        let newDisplayedCount = displayedCount + reveal
        let endIdx = full.index(full.startIndex, offsetBy: newDisplayedCount)
        displayedCount = newDisplayedCount
        let newDisplayContent = String(full[..<endIdx])

        // ── Paragraph boundary (prose freeze) ────────────────────────────────
        let effectiveFrozen = max(frozenToolBoundaryOffset, frozenReasoningBoundaryOffset)
        updateProseBoundary(in: newDisplayContent, effectiveFrozen: effectiveFrozen)

        publishSnapshot(displayContent: newDisplayContent)
    }

    // MARK: - Prose boundary helpers

    /// Minimum characters the live tail must grow beyond the current prose boundary
    /// before it advances. Larger value = fewer live→frozen migrations = fewer visible
    /// reflow/settle pops during streaming. 1200 chars ≈ ~3–5 paragraphs of prose.
    private static let proseBoundaryHysteresis: Int = 1200

    private func updateProseBoundary(in dc: String, effectiveFrozen: Int) {
        if effectiveFrozen > 0 {
            guard dc.count > effectiveFrozen else { return }
            let tailStartIdx = dc.index(dc.startIndex, offsetBy: effectiveFrozen)
            let relCandidate = Self.lastParagraphBoundary(in: String(dc[tailStartIdx...]))
            if relCandidate > 0 {
                let abs = effectiveFrozen + relCandidate
                if abs > frozenProseBoundaryOffset + Self.proseBoundaryHysteresis {
                    frozenProseBoundaryOffset = abs
                }
            }
        } else {
            let candidate = Self.lastParagraphBoundary(in: dc)
            if candidate > frozenProseBoundaryOffset + Self.proseBoundaryHysteresis {
                frozenProseBoundaryOffset = candidate
            }
        }
    }

    // MARK: - Publish (hops to @MainActor)

    /// Builds the snapshot with all pre-sliced strings (off-main), then delivers to @MainActor.
    private func publishSnapshot(displayContent: String) {
        let fb = max(frozenToolBoundaryOffset, frozenReasoningBoundaryOffset)
        let prose = frozenProseBoundaryOffset
        let dcCount = displayContent.count

        var frozenContent = ""
        var liveTail = ""
        var relProse = 0
        var liveTailFrozenProse = ""
        var liveTailLiveProse = ""
        var pureFrozenProse = ""
        var pureLiveProse = ""

        if fb > 0 && dcCount >= fb {
            // Tool/reasoning split — frozenContent is stable once fb stops advancing.
            // Cache the String value so downstream == is O(1) on stable ticks.
            //
            // NOTE: displayContent is a new String allocation every drain tick.
            // Never store or reuse a String.Index across ticks — always recompute fresh.
            let fbIdx = displayContent.index(displayContent.startIndex, offsetBy: fb)
            if _cachedFrozenContent.offset == fb {
                frozenContent = _cachedFrozenContent.value
            } else {
                frozenContent = String(displayContent[..<fbIdx])
                _cachedFrozenContent = (fb, frozenContent)
            }
            liveTail = String(displayContent[fbIdx...])

            // Further split liveTail at prose boundary.
            if prose > fb {
                let relP = prose - fb
                if liveTail.count >= relP {
                    let splitIdx = liveTail.index(liveTail.startIndex, offsetBy: relP)
                    if _cachedLiveTailFrozenProse.offset == prose {
                        liveTailFrozenProse = _cachedLiveTailFrozenProse.value
                    } else {
                        liveTailFrozenProse = String(liveTail[..<splitIdx])
                        _cachedLiveTailFrozenProse = (prose, liveTailFrozenProse)
                    }
                    liveTailLiveProse = String(liveTail[splitIdx...])
                    relProse = relP
                }
            }
        } else if fb == 0 && prose > 0 && dcCount >= prose {
            // Pure-prose split (no tool/reasoning blocks).
            let splitIdx = displayContent.index(displayContent.startIndex, offsetBy: prose)
            if _cachedPureFrozenProse.offset == prose {
                pureFrozenProse = _cachedPureFrozenProse.value
            } else {
                pureFrozenProse = String(displayContent[..<splitIdx])
                _cachedPureFrozenProse = (prose, pureFrozenProse)
            }
            pureLiveProse = String(displayContent[splitIdx...])
        }

        let snap = StreamingSnapshot(
            displayContent: displayContent,
            frozenBoundary: fb,
            frozenContent: frozenContent,
            liveTail: liveTail,
            relProseBoundary: relProse,
            liveTailFrozenProse: liveTailFrozenProse,
            liveTailLiveProse: liveTailLiveProse,
            pureFrozenProse: pureFrozenProse,
            pureLiveProse: pureLiveProse,
            frozenToolBoundaryOffset: frozenToolBoundaryOffset,
            frozenReasoningBoundaryOffset: frozenReasoningBoundaryOffset,
            frozenProseBoundaryOffset: frozenProseBoundaryOffset,
            isActive: true
        )
        Task { @MainActor [onSnapshot] in onSnapshot(snap) }
    }

    // MARK: - Live-preview fence detection (all off-main)

    /// Returns `true` when `content` contains an unclosed live-preview code fence
    /// (` ```html `, ` ```svg `, ` ```mermaid `, ` ```chart* `).
    /// Result is cached by utf8.count — O(1) on repeat calls for the same buffer length.
    private func hasOpenLivePreviewFence(in content: String) -> Bool {
        let count = content.utf8.count
        if let cached = _livePreviewFenceCache, cached.contentCount == count {
            return cached.hasOpen
        }
        let fences = ["```html\n", "```svg\n", "```mermaid\n",
                      "```chart\n", "```chartjs\n", "```echarts\n",
                      "```highcharts\n", "```plotly\n",
                      "```vega-lite\n", "```vegalite\n"]
        var result = false
        let lower = content.lowercased()
        for fence in fences {
            guard let openRange = lower.range(of: fence) else { continue }
            if lower[openRange.upperBound...].range(of: "\n```") == nil {
                result = true
                break
            }
        }
        // VIZ blocks (@@@VIZ-START…@@@VIZ-END) are large HTML payloads — fast-drain.
        if !result && content.contains("@@@VIZ-START") && !content.contains("\n@@@VIZ-END") {
            result = true
        }
        _livePreviewFenceCache = (count, result)
        return result
    }

    // MARK: - Details block detection (all off-main)

    private func toolCallFlags(for content: String) -> ToolCallBlockFlags {
        let count = content.utf8.count
        if let cached = _toolCallFlagsCache, cached.contentCount == count {
            return cached.flags
        }

        // Pre-check: if there's a <details opening tag whose closing > hasn't
        // arrived yet, we can't read its type attribute — freeze immediately so
        // partial HTML never leaks to MarkdownView. This closes the race window
        // where "<details type=\"tool_calls\"" arrives character-by-character
        // and content.contains("tool_calls") is still false for the first few ticks.
        if let detailsRange = content.range(of: "<details") {
            if !content[detailsRange.upperBound...].contains(">") {
                let flags = ToolCallBlockFlags(hasUnclosed: true, hasClosed: false)
                _toolCallFlagsCache = (count, flags)
                return flags
            }
        }

        guard content.contains("tool_calls") else {
            let flags = ToolCallBlockFlags(hasUnclosed: false, hasClosed: false)
            _toolCallFlagsCache = (count, flags)
            return flags
        }

        // Depth-aware scan: walk the content tracking nesting so that nested
        // <details> elements inside tool result HTML (e.g. from web search results)
        // don't corrupt the open/close accounting.
        //
        // For each <details type="tool_calls"> opener we track a depth counter.
        // Only a </details> that brings depth back to 0 truly closes the block.
        // Plain <details> (non-tool_calls, non-reasoning) inside the body bump
        // depth and their corresponding </details> only decrements it — they do
        // NOT count as closing the outer tool_calls block.
        var hasUnclosed = false
        var hasClosed = false

        var idx = content.startIndex
        while idx < content.endIndex {
            guard content[idx] == "<" else {
                idx = content.index(after: idx)
                continue
            }

            let detailsOpenTag = "<details"
            if content[idx...].hasPrefix(detailsOpenTag) {
                // Scan the opening tag with quote-awareness so we correctly
                // find the attribute type even when values contain ">".
                let afterDetails = content.index(idx, offsetBy: detailsOpenTag.count,
                                                 limitedBy: content.endIndex) ?? content.endIndex
                var j = afterDetails
                var inQuote: Character? = nil
                var openingTagEnd: String.Index? = nil
                while j < content.endIndex {
                    let ch = content[j]
                    if let q = inQuote {
                        if ch == q { inQuote = nil }
                    } else {
                        if ch == "\"" || ch == "'" { inQuote = ch }
                        else if ch == ">" { openingTagEnd = content.index(after: j); break }
                    }
                    j = content.index(after: j)
                }

                guard let tagBodyStart = openingTagEnd else {
                    // Opening tag not yet closed — block is still in-flight.
                    hasUnclosed = true
                    break
                }

                let tagText = String(content[idx..<tagBodyStart]).lowercased()
                let isToolCallsBlock = tagText.contains("type=\"tool_calls\"")
                                    || tagText.contains("type='tool_calls'")

                if isToolCallsBlock {
                    // Depth-track to find the matching </details> for this block.
                    var k = tagBodyStart
                    var depth = 1

                    while k < content.endIndex && depth > 0 {
                        guard let nextLt = content[k...].firstIndex(of: "<") else {
                            depth = -1; break   // closing tag not yet arrived
                        }
                        let peekEnd = content.index(nextLt, offsetBy: 9,
                                                    limitedBy: content.endIndex) ?? content.endIndex
                        let peek = content[nextLt..<peekEnd].lowercased()

                        if peek.hasPrefix("</details") {
                            var m = content.index(nextLt, offsetBy: 9,
                                                  limitedBy: content.endIndex) ?? content.endIndex
                            while m < content.endIndex && content[m] != ">" {
                                m = content.index(after: m)
                            }
                            if m < content.endIndex {
                                depth -= 1
                                k = content.index(after: m)
                            } else {
                                depth = -1; break
                            }
                        } else if peek.hasPrefix("<details") {
                            // Nested <details> — skip its opening tag and bump depth.
                            let nestedNameEnd = content.index(nextLt, offsetBy: 8,
                                                              limitedBy: content.endIndex) ?? content.endIndex
                            var m = nestedNameEnd
                            var nestedInQuote: Character? = nil
                            var foundClose = false
                            while m < content.endIndex {
                                let ch = content[m]
                                if let q = nestedInQuote {
                                    if ch == q { nestedInQuote = nil }
                                } else {
                                    if ch == "\"" || ch == "'" { nestedInQuote = ch }
                                    else if ch == ">" { foundClose = true; m = content.index(after: m); break }
                                }
                                m = content.index(after: m)
                            }
                            if foundClose { depth += 1; k = m }
                            else { depth = -1; break }
                        } else {
                            k = content.index(after: nextLt)
                        }
                    }

                    if depth == 0 {
                        hasClosed = true
                    } else {
                        // depth < 0 means the closing tag hasn't arrived yet.
                        hasUnclosed = true
                    }

                    idx = k   // resume scan after this block
                    continue
                } else {
                    idx = tagBodyStart
                    continue
                }
            }

            // Not a <details opener — advance past this '<'
            idx = content.index(after: idx)
        }

        let flags = ToolCallBlockFlags(hasUnclosed: hasUnclosed, hasClosed: hasClosed)
        _toolCallFlagsCache = (count, flags)
        return flags
    }

    private static func lastToolCallDetailsEnd(in content: String) -> Int? {
        guard content.contains("tool_calls") else { return nil }

        // Depth-aware scan: find the end of each top-level <details type="tool_calls">
        // block by tracking nesting so that nested <details> inside tool result HTML
        // (e.g. from web search result snippets) don't cause early termination.
        var lastEnd: String.Index? = nil
        var idx = content.startIndex

        while idx < content.endIndex {
            guard content[idx] == "<" else { idx = content.index(after: idx); continue }

            let detailsOpenTag = "<details"
            guard content[idx...].hasPrefix(detailsOpenTag) else {
                idx = content.index(after: idx); continue
            }

            // Scan the opening tag quote-aware to read the full attribute string.
            let afterDetails = content.index(idx, offsetBy: detailsOpenTag.count,
                                             limitedBy: content.endIndex) ?? content.endIndex
            var j = afterDetails
            var inQuote: Character? = nil
            var openingTagEnd: String.Index? = nil
            while j < content.endIndex {
                let ch = content[j]
                if let q = inQuote {
                    if ch == q { inQuote = nil }
                } else {
                    if ch == "\"" || ch == "'" { inQuote = ch }
                    else if ch == ">" { openingTagEnd = content.index(after: j); break }
                }
                j = content.index(after: j)
            }

            guard let tagBodyStart = openingTagEnd else { break }   // mid-stream

            let tagText = String(content[idx..<tagBodyStart]).lowercased()
            let isToolCallsBlock = tagText.contains("type=\"tool_calls\"")
                                || tagText.contains("type='tool_calls'")

            guard isToolCallsBlock else { idx = tagBodyStart; continue }

            // Depth-track to find the matching </details> for this tool_calls block.
            var k = tagBodyStart
            var depth = 1

            while k < content.endIndex && depth > 0 {
                guard let nextLt = content[k...].firstIndex(of: "<") else {
                    depth = -1; break
                }
                let peekEnd = content.index(nextLt, offsetBy: 9,
                                            limitedBy: content.endIndex) ?? content.endIndex
                let peek = content[nextLt..<peekEnd].lowercased()

                if peek.hasPrefix("</details") {
                    var m = content.index(nextLt, offsetBy: 9,
                                          limitedBy: content.endIndex) ?? content.endIndex
                    while m < content.endIndex && content[m] != ">" {
                        m = content.index(after: m)
                    }
                    if m < content.endIndex {
                        depth -= 1
                        k = content.index(after: m)
                        if depth == 0 { lastEnd = k }
                    } else {
                        depth = -1; break
                    }
                } else if peek.hasPrefix("<details") {
                    let nestedNameEnd = content.index(nextLt, offsetBy: 8,
                                                      limitedBy: content.endIndex) ?? content.endIndex
                    var m = nestedNameEnd
                    var nestedInQuote: Character? = nil
                    var foundClose = false
                    while m < content.endIndex {
                        let ch = content[m]
                        if let q = nestedInQuote {
                            if ch == q { nestedInQuote = nil }
                        } else {
                            if ch == "\"" || ch == "'" { nestedInQuote = ch }
                            else if ch == ">" { foundClose = true; m = content.index(after: m); break }
                        }
                        m = content.index(after: m)
                    }
                    if foundClose { depth += 1; k = m }
                    else { depth = -1; break }
                } else {
                    k = content.index(after: nextLt)
                }
            }

            idx = (depth == 0) ? k : content.endIndex
        }

        guard let e = lastEnd else { return nil }
        return content.distance(from: content.startIndex, to: e)
    }

    // MARK: - Reasoning block detection (mirrors tool_calls path)

    /// Returns flags for `<details type="reasoning">` blocks — same semantics as
    /// `toolCallFlags` but scans for `type="reasoning"` instead of `type="tool_calls"`.
    /// This is intentionally a separate function (not merged with toolCallFlags) so
    /// each has its own cache key and neither pollutes the other's cached state.
    private func reasoningFlags(for content: String) -> ToolCallBlockFlags {
        guard content.contains("reasoning") else {
            return ToolCallBlockFlags(hasUnclosed: false, hasClosed: false)
        }

        var hasUnclosed = false
        var hasClosed = false
        var idx = content.startIndex

        while idx < content.endIndex {
            guard content[idx] == "<" else { idx = content.index(after: idx); continue }

            let detailsOpenTag = "<details"
            guard content[idx...].hasPrefix(detailsOpenTag) else {
                idx = content.index(after: idx); continue
            }

            let afterDetails = content.index(idx, offsetBy: detailsOpenTag.count,
                                             limitedBy: content.endIndex) ?? content.endIndex
            var j = afterDetails
            var inQuote: Character? = nil
            var openingTagEnd: String.Index? = nil
            while j < content.endIndex {
                let ch = content[j]
                if let q = inQuote {
                    if ch == q { inQuote = nil }
                } else {
                    if ch == "\"" || ch == "'" { inQuote = ch }
                    else if ch == ">" { openingTagEnd = content.index(after: j); break }
                }
                j = content.index(after: j)
            }

            guard let tagBodyStart = openingTagEnd else {
                hasUnclosed = true
                break
            }

            let tagText = String(content[idx..<tagBodyStart]).lowercased()
            let isReasoningBlock = tagText.contains("type=\"reasoning\"")
                                || tagText.contains("type='reasoning'")

            if isReasoningBlock {
                var k = tagBodyStart
                var depth = 1

                while k < content.endIndex && depth > 0 {
                    guard let nextLt = content[k...].firstIndex(of: "<") else {
                        depth = -1; break
                    }
                    let peekEnd = content.index(nextLt, offsetBy: 9,
                                                limitedBy: content.endIndex) ?? content.endIndex
                    let peek = content[nextLt..<peekEnd].lowercased()

                    if peek.hasPrefix("</details") {
                        var m = content.index(nextLt, offsetBy: 9,
                                              limitedBy: content.endIndex) ?? content.endIndex
                        while m < content.endIndex && content[m] != ">" {
                            m = content.index(after: m)
                        }
                        if m < content.endIndex {
                            depth -= 1
                            k = content.index(after: m)
                        } else {
                            depth = -1; break
                        }
                    } else if peek.hasPrefix("<details") {
                        let nestedNameEnd = content.index(nextLt, offsetBy: 8,
                                                          limitedBy: content.endIndex) ?? content.endIndex
                        var m = nestedNameEnd
                        var nestedInQuote: Character? = nil
                        var foundClose = false
                        while m < content.endIndex {
                            let ch = content[m]
                            if let q = nestedInQuote {
                                if ch == q { nestedInQuote = nil }
                            } else {
                                if ch == "\"" || ch == "'" { nestedInQuote = ch }
                                else if ch == ">" { foundClose = true; m = content.index(after: m); break }
                            }
                            m = content.index(after: m)
                        }
                        if foundClose { depth += 1; k = m }
                        else { depth = -1; break }
                    } else {
                        k = content.index(after: nextLt)
                    }
                }

                if depth == 0 {
                    hasClosed = true
                } else {
                    hasUnclosed = true
                }

                idx = k
                continue
            } else {
                idx = tagBodyStart
                continue
            }
        }

        return ToolCallBlockFlags(hasUnclosed: hasUnclosed, hasClosed: hasClosed)
    }

    /// Depth-aware scan that finds the character offset just after the last closed
    /// `<details type="reasoning">...</details>` block in `content`.
    /// Returns `nil` if no closed reasoning block exists.
    private static func lastReasoningDetailsEnd(in content: String) -> Int? {
        guard content.contains("reasoning") else { return nil }

        var lastEnd: String.Index? = nil
        var idx = content.startIndex

        while idx < content.endIndex {
            guard content[idx] == "<" else { idx = content.index(after: idx); continue }

            let detailsOpenTag = "<details"
            guard content[idx...].hasPrefix(detailsOpenTag) else {
                idx = content.index(after: idx); continue
            }

            let afterDetails = content.index(idx, offsetBy: detailsOpenTag.count,
                                             limitedBy: content.endIndex) ?? content.endIndex
            var j = afterDetails
            var inQuote: Character? = nil
            var openingTagEnd: String.Index? = nil
            while j < content.endIndex {
                let ch = content[j]
                if let q = inQuote {
                    if ch == q { inQuote = nil }
                } else {
                    if ch == "\"" || ch == "'" { inQuote = ch }
                    else if ch == ">" { openingTagEnd = content.index(after: j); break }
                }
                j = content.index(after: j)
            }

            guard let tagBodyStart = openingTagEnd else { break }

            let tagText = String(content[idx..<tagBodyStart]).lowercased()
            let isReasoningBlock = tagText.contains("type=\"reasoning\"")
                                || tagText.contains("type='reasoning'")

            guard isReasoningBlock else { idx = tagBodyStart; continue }

            var k = tagBodyStart
            var depth = 1

            while k < content.endIndex && depth > 0 {
                guard let nextLt = content[k...].firstIndex(of: "<") else {
                    depth = -1; break
                }
                let peekEnd = content.index(nextLt, offsetBy: 9,
                                            limitedBy: content.endIndex) ?? content.endIndex
                let peek = content[nextLt..<peekEnd].lowercased()

                if peek.hasPrefix("</details") {
                    var m = content.index(nextLt, offsetBy: 9,
                                          limitedBy: content.endIndex) ?? content.endIndex
                    while m < content.endIndex && content[m] != ">" {
                        m = content.index(after: m)
                    }
                    if m < content.endIndex {
                        depth -= 1
                        k = content.index(after: m)
                        if depth == 0 { lastEnd = k }
                    } else {
                        depth = -1; break
                    }
                } else if peek.hasPrefix("<details") {
                    let nestedNameEnd = content.index(nextLt, offsetBy: 8,
                                                      limitedBy: content.endIndex) ?? content.endIndex
                    var m = nestedNameEnd
                    var nestedInQuote: Character? = nil
                    var foundClose = false
                    while m < content.endIndex {
                        let ch = content[m]
                        if let q = nestedInQuote {
                            if ch == q { nestedInQuote = nil }
                        } else {
                            if ch == "\"" || ch == "'" { nestedInQuote = ch }
                            else if ch == ">" { foundClose = true; m = content.index(after: m); break }
                        }
                        m = content.index(after: m)
                    }
                    if foundClose { depth += 1; k = m }
                    else { depth = -1; break }
                } else {
                    k = content.index(after: nextLt)
                }
            }

            idx = (depth == 0) ? k : content.endIndex
        }

        guard let e = lastEnd else { return nil }
        return content.distance(from: content.startIndex, to: e)
    }

    static func lastParagraphBoundary(in text: String, minTailLength: Int = 200) -> Int {
        let minLength = minTailLength + 100
        guard text.count > minLength else { return 0 }
        let safeEndIdx = text.index(text.endIndex, offsetBy: -minTailLength)
        let searchArea = text[text.startIndex..<safeEndIdx]
        guard let lastBlankLine = searchArea.range(of: "\n\n", options: .backwards) else { return 0 }
        let boundaryIdx = lastBlankLine.upperBound
        let textBefore = text[..<boundaryIdx]
        var fenceCount = 0
        var cur = textBefore.startIndex
        while let r = textBefore.range(of: "```", range: cur..<textBefore.endIndex) {
            fenceCount += 1; cur = r.upperBound
        }
        guard fenceCount % 2 == 0 else { return 0 }
        // Don't freeze a boundary inside an open VIZ block — the marker must stay
        // together in pureLiveProse so InlineVisualizerView can detect it.
        let hasUnclosedViz = textBefore.contains("@@@VIZ-START") && !textBefore.contains("\n@@@VIZ-END")
        guard !hasUnclosedViz else { return 0 }
        return text.distance(from: text.startIndex, to: boundaryIdx)
    }
}
