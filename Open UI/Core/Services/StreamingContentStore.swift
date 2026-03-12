import Foundation
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
/// ## Result
/// Per-token work drops from "re-evaluate N message views" to
/// "re-evaluate 1 streaming view" → smooth 60-120 FPS.
@MainActor @Observable
final class StreamingContentStore {
    // MARK: - Live Streaming State

    /// The message ID currently being streamed. `nil` when idle.
    var streamingMessageId: String?

    /// The accumulated content of the streaming message.
    /// Updated on every token (or at the ContentAccumulator's cadence).
    var streamingContent: String = ""

    /// Status history (tool calls, web search progress, etc.)
    var streamingStatusHistory: [ChatStatusUpdate] = []

    /// Sources accumulated during streaming.
    var streamingSources: [ChatSourceReference] = []

    /// Error that occurred during streaming, if any.
    var streamingError: ChatMessageError?

    /// Whether streaming is actively in progress.
    var isActive: Bool = false

    /// The model ID for the streaming message.
    var streamingModelId: String?

    // MARK: - Methods

    /// Starts a new streaming session for a given message.
    func beginStreaming(messageId: String, modelId: String?) {
        streamingMessageId = messageId
        streamingContent = ""
        streamingStatusHistory = []
        streamingSources = []
        streamingError = nil
        streamingModelId = modelId
        isActive = true
    }

    /// Updates the streaming content (called on each token batch).
    func updateContent(_ content: String) {
        streamingContent = content
    }

    /// Appends a status update (tool calls, search progress, etc.)
    func appendStatus(_ status: ChatStatusUpdate) {
        // Deduplicate: update existing in-progress status with same action
        if let existingIdx = streamingStatusHistory.firstIndex(
            where: { $0.action == status.action && $0.done != true }
        ) {
            streamingStatusHistory[existingIdx] = status
        } else {
            let isDuplicate = streamingStatusHistory.contains(where: {
                $0.action == status.action && $0.done == true && status.done == true
            })
            if !isDuplicate {
                streamingStatusHistory.append(status)
            }
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

    /// Ends the streaming session and returns the final content.
    /// The caller is responsible for writing this back to
    /// `conversation.messages`.
    @discardableResult
    func endStreaming() -> StreamingResult {
        let result = StreamingResult(
            messageId: streamingMessageId,
            content: streamingContent,
            statusHistory: streamingStatusHistory,
            sources: streamingSources,
            error: streamingError
        )
        streamingMessageId = nil
        streamingContent = ""
        streamingStatusHistory = []
        streamingSources = []
        streamingError = nil
        streamingModelId = nil
        isActive = false
        return result
    }

    /// Snapshot of the completed streaming session.
    struct StreamingResult {
        let messageId: String?
        let content: String
        let statusHistory: [ChatStatusUpdate]
        let sources: [ChatSourceReference]
        let error: ChatMessageError?
    }
}
