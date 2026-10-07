import Foundation
import os.log

// MARK: - Live Cross-Device Catch-Up: Following a Reply

extension ChatViewModel {

    /// Joins a reply that another device is still generating: marks it streaming, starts
    /// the normal typewriter pipeline from the content the server already has, and lets
    /// the socket deliver the rest.
    func attachToLiveReply(_ serverMessage: ChatMessage, reason: CatchUpReason) {
        // Already following this exact reply.
        if isExternallyStreaming, streamingStore.isActive,
           streamingStore.streamingMessageId == serverMessage.id {
            ensureExternalPollSafetyNet()
            return
        }

        logger.info("Catch-up(\(reason.rawValue)): attaching to live reply \(serverMessage.id) (\(serverMessage.content.count) chars)")
        isSyncingExternalStream = false
        isExternallyStreaming = true
        isStreaming = true
        hasFinishedStreaming = false
        lastCompletedSelfInitiatedMessageId = nil

        let base = serverMessage.content
        externalStreamAccumulatedContent = base
        let modelId = serverMessage.model ?? selectedModelId
        // Seed with what the other device has shown so far; the typewriter continues from
        // here instead of replaying the whole reply.
        streamingStore.beginStreamingForContinue(
            messageId: serverMessage.id, modelId: modelId, existingContent: base)
        updateAssistantMessage(id: serverMessage.id, content: base, isStreaming: true)
        if let idx = conversation?.messages.firstIndex(where: { $0.id == serverMessage.id }) {
            conversation?.messages[idx].isStreaming = true
        }
        ensureExternalPollSafetyNet()
    }

    /// The other device finished while we were following: end the stream cleanly with the
    /// server's final content (the typewriter drains first), then pull files, sources and
    /// follow-ups.
    func finishExternalFollow(with serverMessage: ChatMessage) {
        logger.info("Catch-up: followed reply \(serverMessage.id) finished elsewhere")
        externalStreamPollTask?.cancel()
        externalStreamPollTask = nil
        isSyncingExternalStream = false
        externalStreamAccumulatedContent = ""
        updateAssistantMessage(id: serverMessage.id, content: serverMessage.content, isStreaming: false)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            await self?.syncWithServer(force: true)
        }
    }

    /// A slow safety net in case the socket drops while following a reply: if no token has
    /// arrived for a few seconds, re-read the server's live buffer and feed only the new
    /// text into the same typewriter (never replacing the message). It stops as soon as
    /// the generation ends.
    func ensureExternalPollSafetyNet() {
        guard externalStreamPollTask == nil else { return }
        let chatId = conversationId ?? conversation?.id
        externalStreamPollTask = Task { @MainActor [weak self] in
            var lastSeenLength = self?.externalStreamAccumulatedContent.count ?? 0
            var quietTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled, self.isExternallyStreaming,
                      let chatId, let manager = self.manager else { break }

                let now = self.externalStreamAccumulatedContent.count
                if now != lastSeenLength {            // tokens are flowing: the socket is fine
                    lastSeenLength = now
                    quietTicks = 0
                    continue
                }
                quietTicks += 1
                guard quietTicks >= 2 else { continue }   // about 3 s with no tokens

                guard let serverChat = try? await manager.fetchConversation(id: chatId),
                      let serverLast = serverChat.messages.last(where: { $0.role == .assistant }) else { continue }

                if serverLast.isStreaming {
                    // Still generating: feed anything new into the typewriter.
                    if serverLast.content.count > now,
                       serverLast.content.hasPrefix(self.externalStreamAccumulatedContent) {
                        self.externalStreamAccumulatedContent = serverLast.content
                        self.updateAssistantMessage(id: serverLast.id, content: serverLast.content, isStreaming: true)
                        lastSeenLength = serverLast.content.count
                        quietTicks = 0
                    }
                } else {
                    self.finishExternalFollow(with: serverLast)
                    break
                }
            }
            self?.externalStreamPollTask = nil
        }
    }
}
