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
///
/// ## Tool-call freeze REMOVED
/// Previously the drain cursor was held while an unclosed `<details type="tool_calls">`
/// block was in-flight, which caused the entire message to freeze when a tool call
/// was executing. This was the primary source of user-visible "no output" hangs.
///
/// The fix: the pipeline is now ONLY responsible for typewriter drain of the text
/// content. Tool/reasoning block boundaries still get a **fast-forward** (jump to
/// the end of any CLOSED block so the frozen prefix renders stably), but there is
/// NO freeze on unclosed blocks. If a partial `<details>` is in the buffer the
/// view's HTML parsing will simply skip it (incomplete blocks aren't matched by
/// `findDetailsBlocks` in `ToolCallParser`), so the user sees the text before it.
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

    /// Target drain latency in frames. At 60 Hz ≈ 133 ms of lag.
    private let targetLatencyFrames: Double = 8

    /// Shorter latency used once the server has finished sending.
    private let finishingLatencyFrames: Double = 6

    /// Minimum chars/frame floor — keeps a smooth visible trickle across a 100ms gap.
    private let minRatePerFrame: Double = 1.5

    /// Maximum chars/frame cap — 15 chars/frame × 60 Hz = 900 chars/sec.
    private let maxRatePerFrame: Double = 15.0

    /// Perceptual keep-back: reserve chars so the drain never fully empties the
    /// buffer mid-stream (avoids the "catch-up then pause" stutter).
    /// Disabled when isFinishing (we want to drain to zero).
    private let tailReserve: Int = 8

    // MARK: - EMA smoothing for drain rate

    private let emaAlpha: Double = 0.25
    private var bufferedEMA: Double = 0

    // MARK: - Boundary cache (computed off-main, published via snapshot)

    private var frozenToolBoundaryOffset: Int = 0
    private var frozenReasoningBoundaryOffset: Int = 0
    private var frozenProseBoundaryOffset: Int = 0

    // MARK: - Stable-slice cache (preserves COW identity so downstream == is O(1))

    private var _cachedFrozenContent: (offset: Int, value: String) = (0, "")
    private var _cachedLiveTailFrozenProse: (offset: Int, value: String) = (0, "")
    private var _cachedPureFrozenProse: (offset: Int, value: String) = (0, "")

    // MARK: - Flags cache (keyed by buffer.utf8.count — O(1) after first calc)

    private var _reasoningFlagsCache: (contentCount: Int, hasClosed: Bool)?
    /// Cached result of `hasOpenLivePreviewFence`, keyed by utf8.count.
    private var _livePreviewFenceCache: (contentCount: Int, hasOpen: Bool)?
    /// Cached result of `lastToolCallDetailsEnd`, keyed by utf8.count.
    /// NOTE: We no longer freeze on unclosed tool calls, but we still fast-forward
    /// to the end of CLOSED tool call blocks so the frozen prefix stays stable.
    private var _closedToolEndCache: (contentCount: Int, offset: Int?)?

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
        _reasoningFlagsCache = nil
        _livePreviewFenceCache = nil
        _closedToolEndCache = nil
        _cachedFrozenContent = (0, "")
        _cachedLiveTailFrozenProse = (0, "")
        _cachedPureFrozenProse = (0, "")
    }

    // MARK: - Timer management

    private func startTimer() {
        stopTimer()
        let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
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

        // ── Closed reasoning fast-forward ─────────────────────────────────────
        if hasClosedReasoningBlock(full) {
            if let lastEnd = Self.lastReasoningDetailsEnd(in: full), displayedCount < lastEnd {
                let endIdx = full.index(full.startIndex, offsetBy: lastEnd)
                displayedCount = lastEnd
                frozenReasoningBoundaryOffset = lastEnd
                drainAccumulator = 0
                publishSnapshot(displayContent: String(full[..<endIdx]))
                return
            }
        }

        // ── Closed tool call fast-forward ─────────────────────────────────────
        // Fast-forward to the end of any CLOSED tool call block so the frozen
        // prefix renders stably. Unlike the old design, we do NOT freeze on
        // UNCLOSED blocks — the view handles partial HTML gracefully by simply
        // not matching incomplete `<details>` tags.
        if full.contains("tool_calls") {
            if let lastEnd = cachedLastToolCallDetailsEnd(for: full), displayedCount < lastEnd {
                let endIdx = full.index(full.startIndex, offsetBy: lastEnd)
                displayedCount = lastEnd
                frozenToolBoundaryOffset = lastEnd
                drainAccumulator = 0
                publishSnapshot(displayContent: String(full[..<endIdx]))
                return
            }
        }

        // ── Target-latency drain ──────────────────────────────────────────────
        let fullCount = full.count   // O(N) — paid once, after all early-return branches
        let currentBuffered = fullCount - displayedCount

        let effectiveBuffered = isFinishing ? currentBuffered : max(0, currentBuffered - tailReserve)
        guard effectiveBuffered > 0 else { return }

        let latency = isFinishing ? finishingLatencyFrames : targetLatencyFrames

        bufferedEMA = bufferedEMA * (1.0 - emaAlpha) + Double(effectiveBuffered) * emaAlpha
        let smoothedBuffered = isFinishing ? Double(effectiveBuffered) : max(Double(effectiveBuffered), bufferedEMA)
        let baseRate = smoothedBuffered / latency
        let charsThisFrame: Double

        // Live-preview code fences (html/svg/mermaid/chart) — fast-drain.
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
            let fbIdx = displayContent.index(displayContent.startIndex, offsetBy: fb)
            if _cachedFrozenContent.offset == fb {
                frozenContent = _cachedFrozenContent.value
            } else {
                frozenContent = String(displayContent[..<fbIdx])
                _cachedFrozenContent = (fb, frozenContent)
            }
            liveTail = String(displayContent[fbIdx...])

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
        if !result && content.contains("@@@VIZ-START") && !content.contains("\n@@@VIZ-END") {
            result = true
        }
        _livePreviewFenceCache = (count, result)
        return result
    }

    // MARK: - Closed tool call end (cached, no freeze on unclosed)

    /// Returns the character offset just past the last CLOSED `<details type="tool_calls">`
    /// block, keyed by `utf8.count` for O(1) repeat calls.
    ///
    /// This is used only for fast-forwarding the drain cursor past finished tool call
    /// blocks so the frozen prefix renders stably. We do NOT freeze on unclosed blocks.
    private func cachedLastToolCallDetailsEnd(for content: String) -> Int? {
        let count = content.utf8.count
        if let cached = _closedToolEndCache, cached.contentCount == count {
            return cached.offset
        }
        let offset = Self.lastToolCallDetailsEnd(in: content)
        _closedToolEndCache = (count, offset)
        return offset
    }

    // MARK: - Details block detection (all off-main)

    private func hasClosedReasoningBlock(_ content: String) -> Bool {
        let count = content.utf8.count
        if let cached = _reasoningFlagsCache, cached.contentCount == count {
            return cached.hasClosed
        }
        guard content.contains("reasoning"), content.contains("</details>") else {
            _reasoningFlagsCache = (count, false)
            return false
        }

        var reasoningOpenCount = 0
        var totalCloseCount = 0
        var idx = content.startIndex
        while idx < content.endIndex {
            if content[idx] == "<" {
                let detailsTag = "<details"
                if content[idx...].hasPrefix(detailsTag) {
                    let afterDetails = content.index(idx, offsetBy: detailsTag.count, limitedBy: content.endIndex) ?? content.endIndex
                    var tagEnd = afterDetails
                    while tagEnd < content.endIndex && content[tagEnd] != ">" {
                        tagEnd = content.index(after: tagEnd)
                    }
                    let tagContent = String(content[idx..<tagEnd]).lowercased()
                    if tagContent.contains("reasoning") { reasoningOpenCount += 1 }
                    idx = tagEnd < content.endIndex ? content.index(after: tagEnd) : content.endIndex
                    continue
                }
                let closeTag = "</details>"
                if content[idx...].hasPrefix(closeTag) {
                    totalCloseCount += 1
                    idx = content.index(idx, offsetBy: closeTag.count, limitedBy: content.endIndex) ?? content.endIndex
                    continue
                }
            }
            idx = content.index(after: idx)
        }
        let hasClosed = reasoningOpenCount > 0 && totalCloseCount >= reasoningOpenCount
        _reasoningFlagsCache = (count, hasClosed)
        return hasClosed
    }

    private static func lastReasoningDetailsEnd(in content: String) -> Int? {
        let closeTag = "</details>"
        guard content.contains("reasoning"), content.contains(closeTag) else { return nil }
        var closeEnds: [String.Index] = []
        var sr = content.startIndex..<content.endIndex
        while let r = content.range(of: closeTag, options: .caseInsensitive, range: sr) {
            closeEnds.append(r.upperBound); sr = r.upperBound..<content.endIndex
        }
        var openStarts: [String.Index] = []
        sr = content.startIndex..<content.endIndex
        while let r = content.range(of: "<details", options: .caseInsensitive, range: sr) {
            openStarts.append(r.lowerBound); sr = r.upperBound..<content.endIndex
        }
        guard !closeEnds.isEmpty && !openStarts.isEmpty else { return nil }
        var lastEnd: String.Index? = nil
        let pairCount = min(closeEnds.count, openStarts.count)
        for i in 0..<pairCount {
            if let tagEnd = content.range(of: ">", range: openStarts[i]..<content.endIndex) {
                let tagText = String(content[openStarts[i]..<tagEnd.upperBound]).lowercased()
                if tagText.contains("reasoning") { lastEnd = closeEnds[i] }
            }
        }
        guard let e = lastEnd else { return nil }
        return content.distance(from: content.startIndex, to: e)
    }

    private static func lastToolCallDetailsEnd(in content: String) -> Int? {
        guard content.contains("tool_calls") else { return nil }

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
        let hasUnclosedViz = textBefore.contains("@@@VIZ-START") && !textBefore.contains("\n@@@VIZ-END")
        guard !hasUnclosedViz else { return 0 }
        return text.distance(from: text.startIndex, to: boundaryIdx)
    }
}
