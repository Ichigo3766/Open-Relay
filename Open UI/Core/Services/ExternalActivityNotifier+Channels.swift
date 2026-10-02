import Foundation
import os.log

// MARK: - Channel message classification

extension ExternalActivityNotifier {

    /// Decides whether a channel message should be announced.
    ///
    /// Webhook posts and channel automations are stored under the user's **own**
    /// `user_id`, so they're recognised by their `meta` instead of the sender.
    /// - Parameter api: When non-nil, an automation prompt's thread is fetched to
    ///   find the model's reply (background path). Pass `nil` for live events,
    ///   which deliver thread replies separately.
    func resolveChannelMessage(
        _ message: ChannelMessage,
        channelId: String,
        api: APIClient?,
        eventUserName: String?
    ) async -> ChannelResolution {
        let meta = message.meta ?? [:]
        let isAutomation = meta["automation_id"] != nil
        let myId = currentUserId

        // Model replies: announce once finished (automation replies, or replies to someone else).
        if message.isFromModel {
            guard isAutomation || message.userId != myId else { return .ignore }
            guard message.isModelDone else { return .pending }
            return .notify(messageId: message.id,
                           sender: message.metaModelName ?? message.metaModelId ?? "Assistant",
                           text: message.content)
        }

        // An automation's prompt. In "thread" response mode the reply lives in its thread;
        // otherwise the reply is its own top-level message and is handled on its own.
        if isAutomation {
            guard let api, message.replyCount > 0,
                  let replies = try? await api.getChannelThreadMessages(
                      channelId: channelId, messageId: message.id, limit: 20),
                  let reply = replies
                      .filter({ $0.isFromModel })
                      .max(by: { $0.createdAt < $1.createdAt }) else { return .ignore }
            guard reply.isModelDone else { return .pending }
            return .notify(messageId: reply.id,
                           sender: reply.metaModelName ?? reply.metaModelId ?? "Assistant",
                           text: reply.content)
        }

        // Webhook posts — always announced, even though they carry the creator's user ID.
        if meta["webhook"] != nil || message.isFromWebhook {
            return .notify(messageId: message.id,
                           sender: message.user?.name ?? eventUserName ?? "Webhook",
                           text: message.content)
        }

        // Regular messages: top-level posts from other people.
        guard (message.parentId ?? "").isEmpty else { return .ignore }
        guard let myId, message.userId != myId else { return .ignore }
        return .notify(messageId: message.id,
                       sender: message.user?.name ?? eventUserName ?? "New message",
                       text: message.content)
    }
}
