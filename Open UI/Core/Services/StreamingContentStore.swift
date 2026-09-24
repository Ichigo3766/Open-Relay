import Foundation
import SwiftUI

/// Publishes off-main streaming analysis to the view layer.
@MainActor @Observable
final class StreamingContentStore {
    var streamingMessageId: String?
    var displayContent = ""
    var frozenContent = ""
    var liveTail = ""
    var streamingStatusHistory: [ChatStatusUpdate] = []
    var streamingSources: [ChatSourceReference] = []
    var streamingError: ChatMessageError?
    var isActive = false
    var streamingModelId: String?

    private struct Update: Sendable {
        let content: String
        let isFinal: Bool
    }

    @ObservationIgnored private var updates: AsyncStream<Update>.Continuation?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var rawServerContent = ""
    @ObservationIgnored private var completion: (@MainActor () -> Void)?

    deinit {
        processingTask?.cancel()
        updates?.finish()
    }

    func beginStreaming(messageId: String, modelId: String?) {
        beginStreamingForContinue(messageId: messageId, modelId: modelId, existingContent: "")
    }

    func beginStreamingForContinue(messageId: String, modelId: String?, existingContent: String) {
        processingTask?.cancel()
        updates?.finish()
        completion = nil
        generation &+= 1
        let currentGeneration = generation
        streamingMessageId = messageId
        streamingModelId = modelId
        displayContent = existingContent
        frozenContent = ""
        liveTail = ""
        streamingStatusHistory = []
        streamingSources = []
        streamingError = nil
        isActive = true
        rawServerContent = existingContent

        let pipeline = StreamingPipeline { [weak self] snapshot in
            guard let self, self.generation == currentGeneration else { return }
            self.applySnapshot(snapshot)
        }
        // Only cumulative snapshots may be superseded, never raw token deltas
        // or tool/status events. An idle consumer runs immediately; no timer.
        let (stream, continuation) = AsyncStream<Update>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = continuation
        processingTask = Task {
            await pipeline.beginWithPrefix(existingContent)
            for await update in stream {
                guard !Task.isCancelled else { break }
                if update.isFinal {
                    await pipeline.setFinalContent(update.content)
                } else {
                    await pipeline.append(update.content)
                }
            }
        }
    }

    func updateContent(_ content: String) {
        guard let updates else { return }
        rawServerContent = content
        updates.yield(Update(content: content, isFinal: false))
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

    /// The authoritative final snapshot goes through the same ordered consumer.
    @discardableResult
    func endStreaming(finalContent: String? = nil, onFinished: (@MainActor () -> Void)? = nil) -> StreamingResult {
        guard let updates else { return currentResult() }
        if let finalContent { rawServerContent = finalContent }
        let result = currentResult()
        completion = onFinished
        updates.yield(Update(content: rawServerContent, isFinal: true))
        updates.finish()
        self.updates = nil
        return result
    }

    @discardableResult
    func abortStreaming() -> StreamingResult {
        let result = currentResult()
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

    private func currentResult() -> StreamingResult {
        StreamingResult(
            messageId: streamingMessageId, content: rawServerContent,
            statusHistory: streamingStatusHistory, sources: streamingSources, error: streamingError
        )
    }

    private func applySnapshot(_ snapshot: StreamingSnapshot) {
        guard snapshot.isActive else {
            completeCleanup()
            return
        }
        let didReveal = snapshot.displayContent.utf8.count > displayContent.utf8.count
        displayContent = snapshot.displayContent
        frozenContent = snapshot.frozenContent
        liveTail = snapshot.liveTail
        if didReveal { Haptics.streamingTick() }
    }

    private func completeCleanup() {
        generation &+= 1
        processingTask?.cancel()
        processingTask = nil
        updates?.finish()
        updates = nil
        let onFinished = completion
        completion = nil
        streamingMessageId = nil
        rawServerContent = ""
        displayContent = ""
        frozenContent = ""
        liveTail = ""
        streamingStatusHistory = []
        // Keep sources until the next session so citations survive finalization.
        streamingError = nil
        streamingModelId = nil
        isActive = false
        Haptics.streamingComplete()
        onFinished?()
    }
}
