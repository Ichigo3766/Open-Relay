import Foundation
import os.log

private let pipelineLog = Logger(subsystem: "com.openui", category: "StreamingPipeline")

// MARK: - Streaming Snapshot (main-thread readable output)

/// Immutable snapshot published to the main thread every drain tick.
/// All fields are pre-computed AND pre-sliced by the background actor —
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
///   via `Task { await pipeline.xxx() }`, i.e. always off the main thread by the
///   time they execute inside the actor.
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

    /// Character count of buffer at the last drain tick (used for burst detection).
    private var lastKnownTotal: Int = 0

    // MARK: - Display cursor

    /// How many characters of `buffer` have been revealed to the user.
    private var displayedCount: Int = 0

    // MARK: - Drain state

    private var drainAccumulator: Double = 0
    private var isFinishing: Bool = false

    // MARK: Target-latency drain constants
    //
    // The typewriter reveals content such that the displayed text lags behind
    // the server buffer by ~targetLatencyFrames. Each tick the rate auto-adapts:
    //   rate = buffered / targetLatencyFrames
    // This guarantees continuous motion — no pauses, no dumps.

    /// How many frames of content should remain buffered (visual lag).
    /// 24 frames ≈ 400ms at 60Hz — a comfortable, perceptible typewriter effect.
    private let targetLatencyFrames: Double = 24

    /// Shorter latency used when the server has finished sending (drain remaining
    /// buffer faster so the user isn't waiting unnecessarily).
    private let finishingLatencyFrames: Double = 10

    /// Minimum chars/frame floor — ensures at least a trickle even with tiny buffers.
    private let minRatePerFrame: Double = 0.3

    /// Maximum chars/frame cap — prevents overwhelming MarkdownView on fast models.
    private let maxRatePerFrame: Double = 7.0

    /// Perceptual keep-back: reserve this many chars so the drain never fully
    /// empties the buffer mid-stream (avoids visual "catch-up then pause" stutter).
    /// Disabled when isFinishing (we want to drain to zero).
    private let tailReserve: Int = 2

    // MARK: - Boundary cache (computed off-main, published via snapshot)

    private var frozenToolBoundaryOffset: Int = 0
    private var frozenReasoningBoundaryOffset: Int = 0
    private var frozenProseBoundaryOffset: Int = 0

    // MARK: - Stable-slice cache (preserves COW identity so downstream == is O(1))
    //
    // frozenContent / liveTailFrozenProse / pureFrozenProse only change when their
    // respective boundary offset advances. By storing the last computed String and
    // the offset it was built from, we can hand the *same* String instance to the
    // snapshot when the boundary hasn't moved. Swift String == fast-paths to true
    // instantly when both sides share the same internal buffer (COW pointer equality),
    // so AssistantMessageContent.ParseCache skips its O(N) reparse on stable ticks.
    //
    // `splitIdx` stores the String.Index used to produce the cached slice.
    // On a cache hit the boundary hasn't moved, so `displayContent` has only grown
    // by appending — the stored index is still valid. Reusing it eliminates the
    // repeated `displayContent.index(startIndex, offsetBy: N)` call, which is O(N)
    // and was previously paid on every tick even when the boundary didn't advance.

    private var _cachedFrozenContent: (offset: Int, value: String, splitIdx: String.Index?) = (0, "", nil)
    private var _cachedLiveTailFrozenProse: (offset: Int, value: String, splitIdx: String.Index?) = (0, "", nil)
    private var _cachedPureFrozenProse: (offset: Int, value: String, splitIdx: String.Index?) = (0, "", nil)

    // MARK: - Flags cache (keyed by buffer.utf8.count — fast O(1) after first calc)

    private struct ToolCallBlockFlags {
        let hasUnclosed: Bool
        let hasClosed: Bool
    }
    private var _toolCallFlagsCache: (contentCount: Int, flags: ToolCallBlockFlags)?
    private var _reasoningFlagsCache: (contentCount: Int, hasClosed: Bool)?
    /// Cached result of `hasOpenLivePreviewFence`. Keyed by utf8.count so it
    /// costs O(1) on every tick after the first scan for a given buffer length.
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
        // Publish idle snapshot
        Task { @MainActor [onSnapshot] in onSnapshot(.idle) }
        return result
    }

    // MARK: - Internal reset

    private func resetState() {
        buffer = ""
        lastKnownTotal = 0
        displayedCount = 0
        drainAccumulator = 0
        isFinishing = false
        frozenToolBoundaryOffset = 0
        frozenReasoningBoundaryOffset = 0
        frozenProseBoundaryOffset = 0
        _toolCallFlagsCache = nil
        _reasoningFlagsCache = nil
        _livePreviewFenceCache = nil
        _cachedFrozenContent = (0, "", nil)
        _cachedLiveTailFrozenProse = (0, "", nil)
        _cachedPureFrozenProse = (0, "", nil)
    }

    // MARK: - Timer management

    private func startTimer() {
        stopTimer()
        let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
        // 60 Hz — 16.6ms interval, 0 leeway for minimal jitter.
        // No startup delay needed: the target-latency algorithm naturally produces
        // a very low rate on the first tick (buffer is tiny), preventing any burst.
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // DispatchSource event handlers are NOT actor-isolated — we need to
            // hop into the actor to safely access mutable state.
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

        // Finish-exit: only pay O(N) full.count when isFinishing — zero cost on
        // normal streaming ticks. Character count (not utf8.count) is compared
        // against displayedCount since both are in Swift character units.
        if isFinishing && full.count == displayedCount {
            stopTimer()
            Task { @MainActor [onSnapshot] in onSnapshot(.idle) }
            return
        }

        // ── Tool call fast-forward ────────────────────────────────────────────
        // While an unclosed tool_calls block is in-flight we hold the drain
        // cursor so the user never sees partial HTML. When the server finishes
        // (isFinishing) we fall through to the normal drain so the accumulated
        // content is still revealed — stopping cold would leave the response
        // visually empty even though the full text has been received.
        if toolCallFlags(for: full).hasUnclosed {
            if !isFinishing { return }
            // isFinishing: skip the freeze and let the drain run normally below.
        }

        // ── Closed reasoning fast-forward ─────────────────────────────────────
        if hasClosedReasoningBlock(full) {
            if let lastEnd = Self.lastReasoningDetailsEnd(in: full), displayedCount < lastEnd {
                let endIdx = full.index(full.startIndex, offsetBy: lastEnd)
                displayedCount = lastEnd
                if frozenReasoningBoundaryOffset != lastEnd {
                    frozenReasoningBoundaryOffset = lastEnd
                }
                lastKnownTotal = full.count
                drainAccumulator = 0
                publishSnapshot(displayContent: String(full[..<endIdx]))
                return
            }
        }

        // ── Closed tool call fast-forward ─────────────────────────────────────
        if toolCallFlags(for: full).hasClosed {
            if let lastEnd = Self.lastToolCallDetailsEnd(in: full), displayedCount < lastEnd {
                let endIdx = full.index(full.startIndex, offsetBy: lastEnd)
                displayedCount = lastEnd
                if frozenToolBoundaryOffset != lastEnd {
                    frozenToolBoundaryOffset = lastEnd
                }
                lastKnownTotal = full.count
                drainAccumulator = 0
                publishSnapshot(displayContent: String(full[..<endIdx]))
                return
            }
        }

        // ── Target-latency drain ──────────────────────────────────────────────
        // Each tick, compute a rate that will empty the buffer in exactly
        // `targetLatencyFrames` frames. This adapts instantly to any model speed:
        //   • Slow model (tiny buffer): rate is low → smooth trickle
        //   • Fast model (large buffer): rate is high → keeps up without lag
        //   • Server pauses: buffer empties → rate hits floor → minimal motion
        //   • Server finishes: shorter latency drains remaining buffer faster
        let fullCount = full.count   // O(N) — paid once, after all early-return branches
        let currentBuffered = fullCount - displayedCount

        // Apply tail-reserve: don't drain the last few chars while still streaming.
        // This ensures the reveal never "catches up" to zero and pauses.
        let effectiveBuffered: Int
        if isFinishing {
            effectiveBuffered = currentBuffered
        } else {
            effectiveBuffered = max(0, currentBuffered - tailReserve)
        }
        guard effectiveBuffered > 0 else { return }

        let latency = isFinishing ? finishingLatencyFrames : targetLatencyFrames
        let rate = Double(effectiveBuffered) / latency
        // Live-preview code fences (html/svg/mermaid/chart) are rendered by a WKWebView
        // that handles progressive display itself — the typewriter rate cap is irrelevant
        // and only causes a 36-second delay for a 600-line HTML file. Fast-drain these
        // blocks at 500 chars/frame so the WebView receives content almost immediately.
        let effectiveMaxRate = hasOpenLivePreviewFence(in: full) ? 500.0 : maxRatePerFrame
        let charsThisFrame = min(max(rate, minRatePerFrame), effectiveMaxRate)

        drainAccumulator += charsThisFrame
        let reveal = min(Int(drainAccumulator), currentBuffered)
        guard reveal > 0 else { return }
        drainAccumulator -= Double(reveal)

        let newDisplayedCount = displayedCount + reveal
        let endIdx = full.index(full.startIndex, offsetBy: newDisplayedCount)
        displayedCount = newDisplayedCount
        let newDisplayContent = String(full[..<endIdx])

        // ── Paragraph boundary (prose freeze) ────────────────────────────────
        lastKnownTotal = fullCount  // keep in sync for fast-forward branches that read it
        let effectiveFrozen = max(frozenToolBoundaryOffset, frozenReasoningBoundaryOffset)
        updateProseBoundary(in: newDisplayContent, effectiveFrozen: effectiveFrozen)

        publishSnapshot(displayContent: newDisplayContent)
    }

    // MARK: - Prose boundary helpers

    private static let proseBoundaryHysteresis: Int = 400

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
        // ── Compute frozen/live split ─────────────────────────────────────────
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
            // Reuse cached String instance (preserves COW pointer → downstream == is O(1)).
            let fbIdx: String.Index
            if _cachedFrozenContent.offset == fb, let cachedIdx = _cachedFrozenContent.splitIdx {
                // Cache hit: reuse the stored index — O(1), no traversal from startIndex.
                frozenContent = _cachedFrozenContent.value
                fbIdx = cachedIdx
            } else {
                // Cache miss: compute index once and cache it alongside the string.
                fbIdx = displayContent.index(displayContent.startIndex, offsetBy: fb)
                frozenContent = String(displayContent[..<fbIdx])
                _cachedFrozenContent = (fb, frozenContent, fbIdx)
            }
            // liveTail grows every tick — always a fresh slice using the cached fbIdx.
            liveTail = String(displayContent[fbIdx...])

            // Further split liveTail at prose boundary.
            // liveTailFrozenProse is stable once prose stops advancing — cache it.
            if prose > fb {
                let relP = prose - fb
                if liveTail.count >= relP {
                    if _cachedLiveTailFrozenProse.offset == prose, let cachedSplit = _cachedLiveTailFrozenProse.splitIdx {
                        // Cache hit: reuse stored index — O(1).
                        liveTailFrozenProse = _cachedLiveTailFrozenProse.value
                        liveTailLiveProse = String(liveTail[cachedSplit...])
                    } else {
                        // Cache miss: compute index and cache.
                        let splitIdx = liveTail.index(liveTail.startIndex, offsetBy: relP)
                        liveTailFrozenProse = String(liveTail[..<splitIdx])
                        _cachedLiveTailFrozenProse = (prose, liveTailFrozenProse, splitIdx)
                        liveTailLiveProse = String(liveTail[splitIdx...])
                    }
                    relProse = relP
                }
            }
        } else if fb == 0 && prose > 0 && dcCount >= prose {
            // Pure-prose split (no tool/reasoning blocks).
            // pureFrozenProse is stable once prose stops advancing — cache it.
            if _cachedPureFrozenProse.offset == prose, let cachedSplit = _cachedPureFrozenProse.splitIdx {
                // Cache hit: reuse stored index — O(1), no traversal from startIndex.
                pureFrozenProse = _cachedPureFrozenProse.value
                pureLiveProse = String(displayContent[cachedSplit...])
            } else {
                // Cache miss: compute index and cache.
                let splitIdx = displayContent.index(displayContent.startIndex, offsetBy: prose)
                pureFrozenProse = String(displayContent[..<splitIdx])
                _cachedPureFrozenProse = (prose, pureFrozenProse, splitIdx)
                pureLiveProse = String(displayContent[splitIdx...])
            }
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
    ///
    /// Result is cached by utf8.count — O(1) on repeat calls for the same buffer length.
    /// O(N) scan only fires when new content has been appended.
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
        // Case-insensitive scan using lowercased copy (avoids repeated ICU calls).
        let lower = content.lowercased()
        for fence in fences {
            guard let openRange = lower.range(of: fence) else { continue }
            // If no closing fence follows, the block is still open.
            if lower[openRange.upperBound...].range(of: "\n```") == nil {
                result = true
                break
            }
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

        guard content.contains("tool_calls") else {
            let flags = ToolCallBlockFlags(hasUnclosed: false, hasClosed: false)
            _toolCallFlagsCache = (count, flags)
            return flags
        }

        var toolCallOpenCount = 0
        var totalCloseCount = 0
        var reasoningOpenCount = 0

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
                    if tagContent.contains("tool_calls") {
                        toolCallOpenCount += 1
                    } else if tagContent.contains("type=\"reasoning\"") || tagContent.contains("type='reasoning'") {
                        reasoningOpenCount += 1
                    }
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

        let toolCallCloseCount = max(0, totalCloseCount - reasoningOpenCount)
        let hasUnclosed = toolCallOpenCount > toolCallCloseCount
        let hasClosed = toolCallOpenCount > 0 && !hasUnclosed
        let flags = ToolCallBlockFlags(hasUnclosed: hasUnclosed, hasClosed: hasClosed)
        _toolCallFlagsCache = (count, flags)
        return flags
    }

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
        let closeTag = "</details>"
        guard content.contains("tool_calls"), content.contains(closeTag) else { return nil }
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
        var lastToolCallEnd: String.Index? = nil
        let pairCount = min(closeEnds.count, openStarts.count)
        for i in 0..<pairCount {
            if let tagEnd = content.range(of: ">", range: openStarts[i]..<content.endIndex) {
                let tagText = String(content[openStarts[i]..<tagEnd.upperBound]).lowercased()
                if tagText.contains("tool_calls") { lastToolCallEnd = closeEnds[i] }
            }
        }
        guard let e = lastToolCallEnd else { return nil }
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
        return text.distance(from: text.startIndex, to: boundaryIdx)
    }
}
