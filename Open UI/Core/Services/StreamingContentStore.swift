import Foundation
import QuartzCore
import SwiftUI
import os.log

private let drainLog = Logger(subsystem: "com.openui", category: "DrainTick")

/// Isolates streaming message state from the main conversation model.

@MainActor @Observable
final class StreamingContentStore {
    // MARK: - Live Streaming State

    /// The message ID currently being streamed. `nil` when idle.
    var streamingMessageId: String?

    /// The full accumulated content from the server (ground truth).
    /// Updated on every token — NOT read directly by the view during streaming.
    private(set) var streamingContent: String = ""

    /// The content actually shown to the user — drained smoothly from
    /// `streamingContent` by the proportional drain display link.
    /// Views should read THIS property, not `streamingContent`.
    var displayContent: String = ""

    /// Status history (tool calls, web search progress, etc.)
    var streamingStatusHistory: [ChatStatusUpdate] = []

    /// Sources accumulated during streaming.
    var streamingSources: [ChatSourceReference] = []

    /// Error that occurred during streaming, if any.
    var streamingError: ChatMessageError?

    /// Whether streaming is actively in progress.
    /// Remains `true` during finishing mode (buffer draining after server done).
    var isActive: Bool = false

    /// The model ID for the streaming message.
    var streamingModelId: String?

    // MARK: - Drain State

    private var displayLink: CADisplayLink?

    /// Fractional carry-over from the previous drain tick.
    /// Accumulates sub-integer portions so no chars are lost at low server speeds.
    private var drainAccumulator: Double = 0

    /// Constant chars-per-frame rate, locked when a burst of tokens arrives.
    /// Persists across frames until the next burst recalculates it, ensuring
    /// the buffer drains uniformly over the EMA-estimated inter-burst gap.
    private var steadyRate: Double = 0

    /// Tracks `streamingContent.count` from the previous frame to detect
    /// when new tokens have arrived (burst detection).
    private var lastKnownTotal: Int = 0

    /// Exponential moving average of the inter-burst interval in display-link
    /// frames. Seed at 15 (≈250ms) — fast models often burst every 100-200ms,
    /// so a lower seed prevents over-slow drain at startup.
    /// Updated on every burst: EMA = 0.3 × observed + 0.7 × EMA
    private var burstIntervalEMA: Double = 15

    /// Frame counter incremented every tick, reset to 0 on each burst arrival.
    /// Used to measure the actual gap between consecutive token bursts.
    private var framesSinceLastBurst: Int = 0

    /// True until the first real token burst arrives. Prevents the model's
    /// thinking time (can be seconds → hundreds of frames) from polluting the
    /// EMA with a wildly inflated inter-burst interval.
    private var isFirstBurst: Bool = true

    /// True once the server has finished sending tokens. The display link
    /// keeps running to drain remaining buffer — no new tokens will arrive.
    /// Buffer is NOT instantly flushed; drain continues at the same rate.
    private var isFinishing: Bool = false

    /// Counts frames elapsed since the visible buffer went to zero.
    /// Used for momentum coasting — the drain keeps moving at steadyRate
    /// for up to `maxCoastFrames` frames even when the buffer is empty,
    /// smoothing out the dead zone between irregular token bursts.
    private var coastFrames: Int = 0

    /// Maximum frames to coast at steadyRate after the buffer empties.
    /// At 60fps, 10 frames = ~167ms — enough to bridge most inter-burst gaps
    /// without permanently overshooting when the server really is done.
    private let maxCoastFrames: Int = 10

    /// Hard cap on chars revealed per frame, regardless of server speed.
    /// At 60fps: 6.0 chars/frame = 360 chars/sec — comfortable typewriter pace.
    /// Prevents fast models from dumping large bursts instantly, which destroys
    /// the character-by-character feel. The buffer simply grows and drains steadily.
    private let maxCharsPerFrame: Double = 6.0

    /// True from the frame that VIZ fast-forward is first completed (displayContent
    /// advanced to vizEndOffset) until the next drainTick where we start fresh.
    /// Used to trigger a single drain-state reset at the streaming→typewriter boundary.
    private var vizTransitionPending: Bool = false

    /// Throttle counter for per-frame drain logs — logs every 30 frames (~0.5s).
    private var drainLogCounter: Int = 0

    // MARK: - CADisplayLink (synchronous — no Task trampoline)

    private final class DisplayLinkTarget: NSObject {
        weak var store: StreamingContentStore?
        @objc func tick(_ link: CADisplayLink) {
            guard let store else { return }
            // CADisplayLink fires on the main RunLoop (main thread).
            // assumeIsolated lets us call the @MainActor method synchronously
            // without scheduling an async Task — eliminates tick-queuing jitter.
            MainActor.assumeIsolated { store.drainTick() }
        }
    }

    private var displayLinkTarget: DisplayLinkTarget?

    // MARK: - Methods

    /// Starts a new streaming session for a given message.
    func beginStreaming(messageId: String, modelId: String?) {
        streamingMessageId = messageId
        streamingContent = ""
        displayContent = ""
        streamingStatusHistory = []
        streamingSources = []
        streamingError = nil
        streamingModelId = modelId
        isActive = true
        isFinishing = false
        startDisplayLink()
    }

    /// Updates the streaming content (called on each token batch from the server).
    func updateContent(_ content: String) {
        // Ignore late tokens arriving after the server has signalled completion.
        // Socket events are async and can race with endStreaming(); this guard
        // prevents a stale token from growing streamingContent while isFinishing
        // is true, which would create a buffer the drain algorithm never catches up to.
        guard !isFinishing else { return }
        streamingContent = content
    }

    /// Appends a status update (tool calls, search progress, etc.)
    func appendStatus(_ status: ChatStatusUpdate) {
        if let idx = streamingStatusHistory.firstIndex(
            where: { $0.action == status.action && $0.done != true }
        ) {
            streamingStatusHistory[idx] = status
        } else {
            let isDuplicate = streamingStatusHistory.contains(where: {
                $0.action == status.action && $0.done == true && status.done == true
            })
            if !isDuplicate { streamingStatusHistory.append(status) }
        }
    }

    /// Appends source references.
    func appendSources(_ sources: [ChatSourceReference]) {
        for source in sources {
            if !streamingSources.contains(where: {
                ($0.url != nil && $0.url == source.url) || ($0.id != nil && $0.id == source.id)
            }) {
                streamingSources.append(source)
            }
        }
    }

    /// Sets an error on the streaming message.
    func setError(_ error: ChatMessageError) {
        streamingError = error
    }

    /// Ends the streaming session.
    ///
    /// Returns the full `StreamingResult` immediately so the caller can write
    /// the authoritative content to the conversation model. However, the
    /// display link is kept alive in "finishing" mode — the remaining buffered
    /// characters drain at the **same rate** as during active streaming.
    /// Once the visible buffer is empty the store cleans itself up automatically.
    ///
    /// For abort/cancel paths use `abortStreaming()` which instantly flushes.
    @discardableResult
    func endStreaming() -> StreamingResult {
        let result = StreamingResult(
            messageId: streamingMessageId,
            content: streamingContent,
            statusHistory: streamingStatusHistory,
            sources: streamingSources,
            error: streamingError
        )

        // If there are still chars to drain, enter finishing mode.
        // The display link keeps running; cleanup happens in drainTick().
        if displayContent.count < streamingContent.count {
            isFinishing = true
            // isActive stays true — the streaming view remains visible
        } else {
            // Nothing left to drain — clean up immediately
            completeCleanup()
        }

        return result
    }

    /// Immediately flushes all remaining buffer and stops the display link.
    /// Use this for abort / cancel / error paths where smooth drain is undesirable.
    /// Returns the full `StreamingResult` so callers can persist partial content.
    @discardableResult
    func abortStreaming() -> StreamingResult {
        let result = StreamingResult(
            messageId: streamingMessageId,
            content: streamingContent,
            statusHistory: streamingStatusHistory,
            sources: streamingSources,
            error: streamingError
        )
        stopDisplayLink()
        completeCleanup()
        return result
    }

    struct StreamingResult {
        let messageId: String?
        let content: String
        let statusHistory: [ChatStatusUpdate]
        let sources: [ChatSourceReference]
        let error: ChatMessageError?
    }

    // MARK: - Internal cleanup

    private func completeCleanup() {
        streamingMessageId = nil
        streamingContent = ""
        displayContent = ""
        streamingStatusHistory = []
        streamingSources = []
        streamingError = nil
        streamingModelId = nil
        isActive = false
        isFinishing = false
        stopDisplayLink()
    }

    // MARK: - CADisplayLink

    private func startDisplayLink() {
        stopDisplayLink()
        drainAccumulator = 0
        steadyRate = 0
        lastKnownTotal = 0
        burstIntervalEMA = 15
        framesSinceLastBurst = 0
        coastFrames = 0
        isFirstBurst = true
        vizTransitionPending = false
        let target = DisplayLinkTarget()
        target.store = self
        displayLinkTarget = target
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        drainAccumulator = 0
        steadyRate = 0
        lastKnownTotal = 0
        burstIntervalEMA = 15
        framesSinceLastBurst = 0
        coastFrames = 0
        isFirstBurst = true
        vizTransitionPending = false
    }

    /// Called once per display frame synchronously on the main RunLoop.
    ///
    /// ## EMA burst-interval adaptive drain with momentum coasting
    ///
    /// **Slow model (buffer ≤ 60):** EMA-adaptive constant-rate
    ///   - On burst: update EMA with observed inter-burst frames, then
    ///     `steadyRate = max(buffer / burstIntervalEMA, 0.5)`
    ///   - Each frame: reveal steadyRate chars (constant, not proportional)
    ///   - Buffer drains in exactly `burstIntervalEMA` frames → zero dead zone
    ///   - When buffer empties, coast at steadyRate for up to maxCoastFrames
    ///     to bridge the gap before the next burst arrives
    ///
    /// **Fast model (buffer > 60):** proportional drain
    ///   - Each frame: max(steadyRate, buffer / 6) — proportional dominates
    ///   - Behaviour identical to original — fast models unaffected
    ///
    /// **Finishing mode:** same algorithm, no rate change. Once buffer is
    ///   fully drained, triggers completeCleanup() to stop the display link.
    private func drainTick() {
        let full = streamingContent
        let totalCount = full.count

        // `displayedCount` is read once here and kept in sync if the VIZ
        // fast-forward block mutates `displayContent` mid-tick, so the drain
        // arithmetic below always uses the correct post-fast-forward cursor.
        var displayedCount = displayContent.count
        var buffered = totalCount - displayedCount

        // In finishing mode, if buffer is empty we're done — clean up.
        if isFinishing && buffered == 0 {
            completeCleanup()
            return
        }

        framesSinceLastBurst += 1

        // VIZ fast-forward: if the full content contains VIZ markers, bypass the
        // typewriter drain for the VIZ block itself but NOT for text after @@@VIZ-END.
        //
        // Problem with the old "flush full" approach:
        //   Once @@@VIZ-START appears, `full.contains("@@@VIZ-START")` is permanently
        //   true for the rest of the stream. Every post-VIZ token got dumped instantly
        //   (no typewriter drain), causing choppy text AND forcing MarkdownView to
        //   re-parse the entire multi-KB string at 60fps → 104% CPU.
        //
        // New approach:
        //   - VIZ-START seen, VIZ-END not yet arrived → flush entire buffer (VIZ is
        //     still streaming, we want InlineVisualizerView to render incrementally).
        //   - Both markers present → fast-forward displayContent only up to the end
        //     of @@@VIZ-END (so the viz is fully locked in), then let the normal EMA
        //     typewriter drain handle everything that follows. This restores the smooth
        //     character-by-character feel for any prose written after the viz block.
        if full.contains("@@@VIZ-START") {
            // IMPORTANT: search for "\n@@@VIZ-END" (newline-prefixed) so we only
            // match the standalone end marker that appears on its own line.
            // The VIZ HTML content itself may contain "@@@VIZ-END" as a JavaScript
            // string literal (e.g. `var END_MARK = '@@@VIZ-END'`) — a bare
            // `range(of: "@@@VIZ-END")` would find those embedded occurrences and
            // set vizEndOffset to the wrong position, causing the drain to typewriter
            // raw VIZ JS/HTML as plain message text.
            let standaloneEndMarker = "\n@@@VIZ-END"
            if let endRange = full.range(of: standaloneEndMarker) {
                // Both markers present — fast-forward only through \n@@@VIZ-END.
                let vizEndOffset = full.distance(from: full.startIndex, to: endRange.upperBound)
                if displayedCount < vizEndOffset {
                    // displayContent hasn't reached VIZ-END yet — flush up to it.
                    // Only actually write to displayContent if it changed — avoids
                    // triggering a SwiftUI re-render every frame once VIZ-END is locked.
                    let newDisplay = String(full[..<endRange.upperBound])
                    if displayContent != newDisplay {
                        displayContent = newDisplay
                        drainLog.debug("🎨 [VIZ] VIZ-END reached: vizEndOffset=\(vizEndOffset) totalCount=\(totalCount) postVizBuffered=\(totalCount - vizEndOffset) isFinishing=\(self.isFinishing)")
                    }
                    // Update local cursor so the drain arithmetic below is correct.
                    displayedCount = vizEndOffset
                    buffered = totalCount - displayedCount
                    // Mark that we just landed at VIZ-END — next tick resets drain state.
                    vizTransitionPending = true
                }
                // Fall through to normal drain for text after @@@VIZ-END.
                // (buffered is now full.count - vizEndOffset chars of post-viz prose.)
            } else {
                // @@@VIZ-START seen but standalone @@@VIZ-END not yet arrived —
                // flush everything so InlineVisualizerView gets partial VIZ HTML.
                // Only write to displayContent when it actually changes to avoid
                // spurious SwiftUI re-renders on every display-link tick (60fps)
                // while the VIZ block is rendering (can be 5-10 seconds of frames).
                if displayContent.count != totalCount {
                    displayContent = full
                    drainLog.debug("🎨 [VIZ] VIZ streaming: flushed to \(totalCount) chars (no VIZ-END yet)")
                }
                if isFinishing { completeCleanup() }
                return
            }
        }

        // Tool call / reasoning block fast-forward:
        // When a <details type="tool_calls"> or <details type="reasoning"> block
        // is present but not yet closed (i.e., still streaming), bypassing the
        // typewriter drain prevents the incomplete HTML from leaking into
        // MarkdownView as raw text — which would cause expensive CommonMark
        // parsing + syntax highlighting on the entire block on every display-link
        // tick (60fps). This is especially costly for the Inline Visualizer tool
        // which embeds thousands of characters of HTML/JS in the arguments attribute.
        //
        // Strategy: if the number of <details opens exceeds the number of
        // </details> closes, there is at least one unclosed block — flush immediately.
        // Simple substring counting is O(n) but far cheaper than regex and runs
        // on the RAW full string before any drain decisions.
        if Self.hasUnclosedDetailsBlock(full) {
            // Only write to displayContent when content actually grew — avoids
            // triggering a SwiftUI re-render (and VizMarkerParser.streamingParse scan)
            // on every display-link tick while the <details> block is streaming.
            if displayContent.count != totalCount {
                displayContent = full
            }
            if isFinishing { completeCleanup() }
            return
        }

        // VIZ transition: we just completed the fast-forward to VIZ-END on the
        // previous tick. Reset all drain state so the EMA algorithm starts fresh
        // for post-VIZ prose rather than inheriting a stale lastKnownTotal (which
        // was 0 since early-return paths never updated it) that would make newChars
        // look like the entire 30KB message arrived in one burst.
        //
        // Additionally, if the server already finished while VIZ was rendering
        // (isFinishing=true) and there's a large post-VIZ buffer, flush most of it
        // immediately so the user sees the text appear quickly rather than waiting
        // minutes for a 360-char/sec drain to catch up.
        if vizTransitionPending {
            vizTransitionPending = false
            drainLog.debug("🔄 [VIZ→DRAIN] Transition fired: buffered=\(buffered) isFinishing=\(self.isFinishing) totalCount=\(totalCount)")
            // Sync lastKnownTotal so newChars = 0 on this tick (clean slate).
            lastKnownTotal = totalCount
            // Fresh EMA seed — post-VIZ tokens are actively arriving.
            burstIntervalEMA = 8
            framesSinceLastBurst = 0
            isFirstBurst = true
            drainAccumulator = 0
            steadyRate = 0

            // Catch-up flush: if we're finishing (server done) and the post-VIZ
            // buffer is large, advance displayContent to leave only a small tail
            // (~2 seconds worth at 360 chars/sec) for typewriter effect.
            // Without this, a 5000-char post-VIZ story would take ~14 seconds to
            // drain even after the server finished sending it.
            let catchUpThreshold = 200
            if isFinishing && buffered > catchUpThreshold {
                let keepForTypewriter = catchUpThreshold
                let skipTo = totalCount - keepForTypewriter
                let skipIdx = full.index(full.startIndex, offsetBy: skipTo)
                displayContent = String(full[..<skipIdx])
                displayedCount = skipTo
                buffered = keepForTypewriter
                lastKnownTotal = totalCount
                drainLog.debug("🔄 [VIZ→DRAIN] Catch-up flush: skipped to \(skipTo), leaving \(keepForTypewriter) chars for typewriter")
            }
            // Return — start normal drain on the next tick with clean state.
            return
        }

        // Burst detection: did streamingContent grow since the last frame?
        // In finishing mode this will always be 0 (no new tokens arrive).
        let newChars = totalCount - lastKnownTotal
        lastKnownTotal = totalCount

        if newChars > 0 {
            // Reset coast counter — we have real buffer to drain.
            coastFrames = 0

            if isFirstBurst {
                // Skip EMA update on the very first burst to prevent the model's
                // thinking time (potentially seconds = hundreds of frames) from
                // inflating burstIntervalEMA and making the first drain far too slow.
                // Use the seeded EMA value (15 frames ≈ 250ms) for the first burst.
                isFirstBurst = false
            } else {
                // Update EMA with the observed inter-burst interval (frames).
                // Clamp to [3, 60] — real inter-burst gaps are 6-36 frames at
                // 20-60 tok/s. Ceiling of 60 (1s) prevents one long gap from
                // dragging the EMA high and slowing subsequent bursts.
                // Floor raised to 3 (was 4) for faster responsiveness on fast models.
                let observed = Double(max(3, min(framesSinceLastBurst, 60)))
                burstIntervalEMA = 0.3 * observed + 0.7 * burstIntervalEMA
            }
            framesSinceLastBurst = 0

            // Lock in a constant drain rate that spreads the current buffer
            // across the EMA-estimated inter-burst gap. Floor raised to 0.5
            // (was 0.3) — 30 chars/sec minimum keeps motion visible even
            // during sparse token arrivals.
            steadyRate = max(Double(buffered) / burstIntervalEMA, 0.5)
            drainLog.debug("⚡️ [BURST] newChars=\(newChars) buffered=\(buffered) steadyRate=\(String(format: "%.2f", self.steadyRate)) ema=\(String(format: "%.1f", self.burstIntervalEMA)) isFinishing=\(self.isFinishing)")
        }

        // Threshold-gated dual mode:
        // ≤ 60 chars → EMA-adaptive constant rate (slow model: zero dead zone)
        // > 60 chars → proportional drain (fast model: keeps up with throughput)
        //
        // Note: No tail-reserve brake. The previous 0-3 char brake was the primary
        // source of the "snap then pause" hiccup — it slowed drain to near-zero
        // right when a burst was imminent. Momentum coasting replaces it: when
        // the buffer runs dry we coast at steadyRate until the next burst.
        var charsThisFrame: Double
        if buffered > 60 {
            // Fast model: proportional drain dominates.
            // Dynamic cap: scale the ceiling with buffer depth so post-VIZ catch-up
            // isn't permanently throttled by the normal 6 char/frame typewriter cap.
            //   buffer >   60 → cap = 15 chars/frame  (900 chars/sec — snappy, readable)
            //   buffer >  200 → cap = 30 chars/frame  (1800 chars/sec — fast catch-up)
            //   buffer > 1000 → cap = 50 chars/frame  (3000 chars/sec — aggressive catch-up)
            // The previous thresholds (500/2000) left the drain capped at 6 chars/frame for
            // the entire time buffer stays in the 60–500 range (common during post-VIZ token
            // trickle-in), making text feel sluggish. Lowering to 60/200/1000 ensures we
            // always drain noticeably faster than the 6-char/frame slow path.
            let dynamicCap: Double
            if buffered > 1000 {
                dynamicCap = 50.0
            } else if buffered > 200 {
                dynamicCap = 30.0
            } else {
                dynamicCap = 15.0
            }
            charsThisFrame = min(max(steadyRate, Double(buffered) / 6.0), dynamicCap)
        } else if buffered > 0 {
            // Slow/medium model: constant EMA rate, capped at maxCharsPerFrame
            charsThisFrame = min(steadyRate, maxCharsPerFrame)
        } else {
            // Buffer is empty — momentum coasting:
            // Continue accumulating at steadyRate for up to maxCoastFrames
            // so that when the next burst arrives, the accumulator already
            // has some credit and characters appear immediately.
            guard !isFinishing && coastFrames < maxCoastFrames && steadyRate > 0 else {
                return
            }
            coastFrames += 1
            drainAccumulator += steadyRate
            // Don't reveal any chars — just pre-charge the accumulator.
            // (The accumulator credit will be consumed when buffered > 0 again.)
            return
        }

        drainAccumulator += charsThisFrame
        let reveal = min(Int(drainAccumulator), buffered)
        guard reveal > 0 else { return }
        drainAccumulator -= Double(reveal)

        drainLogCounter += 1
        if drainLogCounter >= 30 {
            drainLogCounter = 0
            drainLog.debug("🖊 [DRAIN] reveal=\(reveal) buffered=\(buffered) steadyRate=\(String(format: "%.2f", self.steadyRate)) charsThisFrame=\(String(format: "%.2f", charsThisFrame)) isFinishing=\(self.isFinishing)")
        }

        let endOffset = displayedCount + reveal
        let endIdx = full.index(full.startIndex, offsetBy: endOffset)
        displayContent = String(full[..<endIdx])
    }

    // MARK: - Details Block Detection

    /// Returns `true` if `content` contains at least one `<details` opening tag
    /// that does not have a matching `</details>` closing tag.
    ///
    /// This is used to fast-forward tool call and reasoning blocks so that the
    /// incomplete HTML is never passed through MarkdownView character by character.
    ///
    /// Uses simple substring counting (not regex) for performance — this runs
    /// on every display-link tick (up to 60fps) so it must be O(n) and cheap.
    private static func hasUnclosedDetailsBlock(_ content: String) -> Bool {
        guard content.contains("<details") else { return false }

        // Count opening <details tags (case-insensitive substring count)
        var openCount = 0
        var searchRange = content.startIndex..<content.endIndex
        let openTag = "<details"
        while let range = content.range(of: openTag, options: .caseInsensitive, range: searchRange) {
            openCount += 1
            searchRange = range.upperBound..<content.endIndex
        }

        // Count closing </details> tags
        var closeCount = 0
        searchRange = content.startIndex..<content.endIndex
        let closeTag = "</details>"
        while let range = content.range(of: closeTag, options: .caseInsensitive, range: searchRange) {
            closeCount += 1
            searchRange = range.upperBound..<content.endIndex
        }

        return openCount > closeCount
    }
}
