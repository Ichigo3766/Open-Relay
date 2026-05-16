import Foundation
import SwiftUI
import UIKit
import os.log

// MARK: - StreamingContentStore (thin @MainActor observable wrapper)

/// Bridges between the background `StreamingPipeline` actor and the SwiftUI
/// view layer. The only work done on the main thread is writing the fields
/// received from the background actor into observable properties — no O(N)
/// string scanning, no string slicing, no regex, nothing heavy.
@MainActor @Observable
final class StreamingContentStore {

    // MARK: - Live Streaming State (read by views)

    /// The message ID currently being streamed. `nil` when idle.
    var streamingMessageId: String?

    // MARK: Pre-sliced display strings (all computed off-main by StreamingPipeline)

    /// Full typewriter-drained content. Views should read sliced variants below instead.
    var displayContent: String = ""

    /// Effective frozen boundary = max(tool, reasoning) offsets. 0 when no closed block yet.
    var frozenBoundary: Int = 0

    /// displayContent[..<frozenBoundary] — stable tool/reasoning HTML. "" when frozenBoundary==0.
    var frozenContent: String = ""

    /// displayContent[frozenBoundary...] — tiny live prose tail. "" when frozenBoundary==0.
    var liveTail: String = ""

    /// Within liveTail: settled paragraphs up to prose boundary. "" when N/A.
    var liveTailFrozenProse: String = ""

    /// Within liveTail: current in-progress paragraph. "" when N/A.
    var liveTailLiveProse: String = ""

    /// Pure-prose (no tool/reasoning): displayContent[..<proseBoundary]. "" when N/A.
    var pureFrozenProse: String = ""

    /// Pure-prose (no tool/reasoning): displayContent[proseBoundary...]. "" when N/A.
    var pureLiveProse: String = ""

    // MARK: Boundary offsets (for has-special-content checks in the view)
    var frozenToolBoundaryOffset: Int = 0
    var frozenReasoningBoundaryOffset: Int = 0
    var frozenProseBoundaryOffset: Int = 0

    // MARK: - Metadata

    /// Status history (tool calls, web search progress, etc.)
    var streamingStatusHistory: [ChatStatusUpdate] = []

    /// Sources accumulated during streaming.
    var streamingSources: [ChatSourceReference] = []

    /// Error that occurred during streaming, if any.
    var streamingError: ChatMessageError?

    /// Whether streaming is actively in progress (including finishing drain).
    var isActive: Bool = false

    /// The model ID for the streaming message.
    var streamingModelId: String?

    // MARK: - Private: background actor

    private var pipeline: StreamingPipeline?

    /// The full raw server content (stored so `endStreaming()` can return it).
    private var rawServerContent: String = ""

    // MARK: - Begin / Update / End

    /// Starts a new streaming session.
    func beginStreaming(messageId: String, modelId: String?) {
        streamingMessageId = messageId
        streamingModelId = modelId
        resetSnapshotFields()
        streamingStatusHistory = []
        streamingSources = []
        streamingError = nil
        isActive = true
        rawServerContent = ""

        let p = StreamingPipeline { [weak self] snapshot in
            guard let self else { return }
            self.applySnapshot(snapshot)
        }
        pipeline = p
        Task { await p.begin() }
    }

    /// Updates the raw server content (called per token batch).
    func updateContent(_ content: String) {
        rawServerContent = content
        let p = pipeline
        Task { await p?.append(content) }
    }

    /// Appends a status update.
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

    /// Callback invoked on @MainActor when the drain pipeline fully empties.
    /// Set by the caller before `endStreaming()` to defer UI finalization until
    /// all buffered tokens are displayed — prevents premature stop-button removal.
    var drainCompletion: (@MainActor () -> Void)?

    /// Ends the streaming session gracefully.
    @discardableResult
    func endStreaming(onDrained: (@MainActor () -> Void)? = nil) -> StreamingResult {
        let result = StreamingResult(
            messageId: streamingMessageId,
            content: rawServerContent,
            statusHistory: streamingStatusHistory,
            sources: streamingSources,
            error: streamingError
        )
        drainCompletion = onDrained
        let p = pipeline
        Task { await p?.finish() }
        return result
    }

    /// Immediately flushes the buffer and stops the pipeline.
    @discardableResult
    func abortStreaming() -> StreamingResult {
        let p = pipeline
        pipeline = nil
        Task { _ = await p?.abort() }
        let result = StreamingResult(
            messageId: streamingMessageId,
            content: rawServerContent,
            statusHistory: streamingStatusHistory,
            sources: streamingSources,
            error: streamingError
        )
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

    // MARK: - Snapshot application (called on @MainActor by pipeline)

    private func applySnapshot(_ snapshot: StreamingSnapshot) {
        if snapshot.isActive {
            // Fire haptic in sync with the typewriter drain — characters are
            // actually appearing on screen right now. Using utf8.count is O(1)
            // (Swift stores it directly on the String) and avoids a full O(N)
            // character count call on every 60 Hz tick.
            let didReveal = snapshot.displayContent.utf8.count > displayContent.utf8.count
            displayContent               = snapshot.displayContent
            frozenBoundary               = snapshot.frozenBoundary
            frozenContent                = snapshot.frozenContent
            liveTail                     = snapshot.liveTail
            liveTailFrozenProse          = snapshot.liveTailFrozenProse
            liveTailLiveProse            = snapshot.liveTailLiveProse
            pureFrozenProse              = snapshot.pureFrozenProse
            pureLiveProse                = snapshot.pureLiveProse
            frozenToolBoundaryOffset     = snapshot.frozenToolBoundaryOffset
            frozenReasoningBoundaryOffset = snapshot.frozenReasoningBoundaryOffset
            frozenProseBoundaryOffset    = snapshot.frozenProseBoundaryOffset
            if didReveal { Haptics.streamingTick() }
        } else {
            completeCleanup()
        }
    }

    // MARK: - Internal cleanup

    private func resetSnapshotFields() {
        displayContent = ""
        frozenBoundary = 0
        frozenContent = ""
        liveTail = ""
        liveTailFrozenProse = ""
        liveTailLiveProse = ""
        pureFrozenProse = ""
        pureLiveProse = ""
        frozenToolBoundaryOffset = 0
        frozenReasoningBoundaryOffset = 0
        frozenProseBoundaryOffset = 0
    }

    private func completeCleanup() {
        // Capture and clear the drain completion before modifying any state,
        // so it fires with the final display content still accessible.
        let completion = drainCompletion
        drainCompletion = nil

        pipeline = nil
        streamingMessageId = nil
        rawServerContent = ""
        resetSnapshotFields()
        streamingStatusHistory = []
        // NOTE: streamingSources is intentionally NOT cleared here.
        // It persists until the next beginStreaming() so IsolatedAssistantMessage
        // can fall back to them during the brief window when isActive=false but
        // message.sources hasn't been committed yet.
        streamingError = nil
        streamingModelId = nil
        isActive = false

        // Fire drain completion AFTER state is clean so the callback's
        // message.isStreaming = false and cleanupStreaming() see a fully
        // idle store and don't re-trigger double cleanup.
        completion?()
    }
}
