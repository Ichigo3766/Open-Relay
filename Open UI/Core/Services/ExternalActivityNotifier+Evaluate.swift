import Foundation
import os.log

// MARK: - Shared evaluation (used by live + background paths)

extension ExternalActivityNotifier {

    enum ChatOutcome { case notified, skipped, pending }

    enum ChannelResolution {
        case ignore
        case pending
        case notify(messageId: String, sender: String, text: String)
    }

    // MARK: Chats

    /// Recent chats this device didn't create and hasn't evaluated yet (max 5, oldest first).
    func chatCandidates(_ summaries: [Conversation], key: String) -> [Conversation] {
        let state = loadState(key)
        let now = Date().timeIntervalSince1970
        let candidates = summaries.filter { chat in
            let created = chat.createdAt.timeIntervalSince1970
            return state.seenChatIds[chat.id] == nil
                && created >= state.baseline
                && now - created < maxChatAge
                && !LocalChatOrigin.contains(chat.id)
        }
        return Array(candidates.sorted { $0.createdAt < $1.createdAt }.suffix(5))
    }

    /// The finished assistant reply of a chat, or `nil` while it's still generating.
    func chatReply(_ conversation: Conversation) -> String? {
        guard let reply = conversation.messages.last(where: { $0.role == .assistant }) else { return nil }
        if let error = reply.error { return error.content ?? "Something went wrong" }
        return reply.isStreaming ? nil : reply.content
    }

    func evaluateChat(_ conversation: Conversation, key: String) async -> ChatOutcome {
        let state = loadState(key)
        guard state.seenChatIds[conversation.id] == nil else { return .skipped }

        let created = conversation.createdAt.timeIntervalSince1970
        let age = Date().timeIntervalSince1970 - created
        guard created >= state.baseline, age < maxChatAge,
              !LocalChatOrigin.contains(conversation.id) else {
            markChatSeen(conversation.id, key: key)
            return .skipped
        }

        guard let reply = chatReply(conversation) else {
            if age > stalePendingAge {
                markChatSeen(conversation.id, key: key)
                return .skipped
            }
            return .pending
        }

        markChatSeen(conversation.id, key: key)
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        await NotificationService.shared.notifyGenerationComplete(
            conversationId: conversation.id,
            title: title.isEmpty ? "New Chat" : title,
            preview: reply.isEmpty ? "Response is ready" : reply
        )
        logger.info("Notified external chat \(conversation.id, privacy: .public)")
        return .notified
    }

    // MARK: Channel helpers

    func channelTitle(_ channel: Channel) -> String {
        guard channel.type == .dm else { return "#\(channel.name)" }
        let others = channel.dmParticipants
            .filter { $0.id != currentUserId }
            .map(\.displayName)
        if !others.isEmpty { return others.joined(separator: ", ") }
        return channel.name.isEmpty ? "Direct Message" : channel.name
    }

    func deliverChannelNotification(
        channelId: String, title: String, sender: String, text: String,
        messageId: String, key: String
    ) async {
        guard loadState(key).notifiedMessageIds[messageId] == nil else { return }
        mutateState(key) { $0.notifiedMessageIds[messageId] = Date().timeIntervalSince1970 }

        let cleaned = NotificationService.stripThinkingAndToolBlocks(from: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = cleaned.count > 120 ? "\(cleaned.prefix(120))…" : cleaned
        await NotificationService.shared.notifyChannelMessage(
            channelId: channelId,
            channelName: title,
            senderName: sender,
            preview: preview
        )
    }
}
