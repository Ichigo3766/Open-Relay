import Foundation
import QuartzCore
import SwiftUI

/// Isolates streaming message state from the main conversation model.
///
/// ## Purpose
/// During AI response streaming, every incoming token was mutating
/// `conversation.messages[index].content` which — via `@Observable` on
/// `ChatViewModel` — invalidated every view reading `messages`. That
/// caused the **entire** message list (including large, completed messages)
/// to re-evaluate their SwiftUI bodies on every token, destroying
/// frame rate.
///
/// `StreamingContentStore` breaks this observation chain:
/// - Token updates go to `streamingContent` on this separate `@Observable`
/// - Only the **one** message view that is actively streaming observes
///   this store. All other message views read from
///   `conversation.messages` which stays frozen during streaming.
/// - When streaming completes, final content is written back to
///   `conversation.messages` **once**.
///
/// ## Token Drain (EMA Burst-Interval Adaptive Typewriter)
/// Rather than passing every raw server token directly to the markdown
/// renderer, `displayContent` drains from `streamingContent` at a
/// **self-regulating rate** driven by a `CADisplayLink`.
///
/// ### How it works
/// Two modes, threshold-gated on buffer size:
///
/// **Slow model (buffer ≤ 40 chars):** EMA-adaptive constant-rate drain.
/// When a burst of tokens arrives the inter-burst interval (frames elapsed
/// since the previous burst) is fed into an exponential moving average:
///   `burstIntervalEMA = 0.3 * framesSinceLastBurst + 0.7 * burstIntervalEMA`
/// `steadyRate` is then locked at:
///   `steadyRate = max(buffer / burstIntervalEMA, 0.3)`
/// Because `burstIntervalEMA` tracks the *actual* gap between TCP bursts,
/// the buffer is consumed in exactly that many frames — eliminating the
/// inter-burst dead zone that caused the "snap then silence" artefact.
///
/// **Fast model (buffer > 40 chars):** Proportional drain.
///   `charsPerFrame = max(steadyRate, buffer / 6)`
/// The large buffer means buffer/6 always wins — identical to original
/// proportional behaviour. Fast models are completely unaffected.
///
/// ### Why EMA beats a fixed divisor
/// A hardcoded divisor of 20 (333ms) works only when bursts arrive every
/// 333ms. At 20 tok/s bursts arrive every ~400-500ms, leaving a ~100-170ms
/// dead zone per burst. The EMA divisor stretches the drain to match the
/// real inter-burst interval, producing a steady typewriter cadence at any
/// server speed.
///
/// ### Why synchronous CADisplayLink (no Task trampoline)
/// CADisplayLink already fires on the main RunLoop (main thread). Using
/// `MainActor.assumeIsolated` lets `drainTick()` execute synchronously
/// within the same RunLoop iteration, eliminating the Task-scheduler hop
/// that previously caused ticks to queue up and fire back-to-back.
///
/// ### Finishing mode
/// When the server completes (`endStreaming()` is called), the store
/// enters `isFinishing` mode instead of instantly flushing remaining
/// buffered content. The display link keeps running at the **same drain
/// rate** until every buffered character has been revealed, then cleans
/// up automatically. This prevents the jarring "dump all at once" artifact
/// at the end of a response while keeping the API identical for callers.
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
    /// frames. Seed at 25 (≈417ms) — matches the typical 400ms gap at 20 tok/s.
    /// Updated on every burst: EMA = 0.3 × observed + 0.7 × EMA
    private var burstIntervalEMA: Double = 25

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
        burstIntervalEMA = 25
        framesSinceLastBurst = 0
        isFirstBurst = true
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
        burstIntervalEMA = 25
        framesSinceLastBurst = 0
        isFirstBurst = true
    }

    /// Called once per display frame synchronously on the main RunLoop.
    ///
    /// ## EMA burst-interval adaptive drain
    ///
    /// **Slow model (buffer ≤ 40):** EMA-adaptive constant-rate
    ///   - On burst: update EMA with observed inter-burst frames, then
    ///     `steadyRate = max(buffer / burstIntervalEMA, 0.3)`
    ///   - Each frame: reveal steadyRate chars (constant, not proportional)
    ///   - Buffer drains in exactly `burstIntervalEMA` frames → zero dead zone
    ///
    /// **Fast model (buffer > 40):** proportional drain
    ///   - Each frame: max(steadyRate, buffer / 6) — proportional dominates
    ///   - Behaviour identical to original — fast models unaffected
    ///
    /// **Finishing mode:** same algorithm, no rate change. Once buffer is
    ///   fully drained, triggers completeCleanup() to stop the display link.
    private func drainTick() {
        let full = streamingContent
        let displayed = displayContent
        let totalCount = full.count
        let buffered = totalCount - displayed.count

        // In finishing mode, if buffer is empty we're done — clean up.
        if isFinishing && buffered == 0 {
            completeCleanup()
            return
        }

        framesSinceLastBurst += 1

        guard buffered > 0 else { return }

        // Burst detection: did streamingContent grow since the last frame?
        // In finishing mode this will always be 0 (no new tokens arrive).
        let newChars = totalCount - lastKnownTotal
        lastKnownTotal = totalCount

        if newChars > 0 {
            if isFirstBurst {
                // Skip EMA update on the very first burst to prevent the model's
                // thinking time (potentially seconds = hundreds of frames) from
                // inflating burstIntervalEMA and making the first drain far too slow.
                // Use the seeded EMA value (25 frames ≈ 417ms) for the first burst.
                isFirstBurst = false
            } else {
                // Update EMA with the observed inter-burst interval (frames).
                // Clamp to [4, 60] — real inter-burst gaps are 12-36 frames at
                // 20-60 tok/s. Ceiling of 60 (1s) prevents one long gap from
                // dragging the EMA high and slowing subsequent bursts.
                let observed = Double(max(4, min(framesSinceLastBurst, 60)))
                burstIntervalEMA = 0.3 * observed + 0.7 * burstIntervalEMA
            }
            framesSinceLastBurst = 0

            // Lock in a constant drain rate that spreads the current buffer
            // across the EMA-estimated inter-burst gap.  Floor of 0.3 lets
            // very small bursts over long gaps trickle out gradually.
            steadyRate = max(Double(buffered) / burstIntervalEMA, 0.3)
        }

        // Threshold-gated dual mode:
        // ≤ 40 chars → EMA-adaptive constant rate (slow model: zero dead zone)
        // > 40 chars → proportional drain (fast model: keeps up with throughput)
        var charsThisFrame: Double
        if buffered <= 40 {
            charsThisFrame = steadyRate

            // Tail-reserve brake: when only 3 or fewer chars remain AND we are
            // still actively receiving tokens (not finishing), apply a quadratic
            // slow-down so the last chars linger until the next burst arrives.
            // During finishing mode we skip this so the tail drains naturally.
            if buffered <= 3 && !isFinishing {
                let brakeFactor = (Double(buffered) / 4.0)  // 0.25 … 0.75
                charsThisFrame = steadyRate * brakeFactor
            }
        } else {
            charsThisFrame = max(steadyRate, Double(buffered) / 6.0)
        }

        drainAccumulator += charsThisFrame
        let reveal = min(Int(drainAccumulator), buffered)
        guard reveal > 0 else { return }
        drainAccumulator -= Double(reveal)

        let endOffset = displayed.count + reveal
        let endIdx = full.index(full.startIndex, offsetBy: endOffset)
        let newDisplay = String(full[..<endIdx])
        displayContent = newDisplay
    }
}
