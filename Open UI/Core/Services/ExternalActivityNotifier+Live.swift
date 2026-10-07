import Foundation
import os.log

// MARK: - Live (socket) delivery

extension ExternalActivityNotifier {

    /// Subscribes to the active socket. Call whenever the socket is (re)created;
    /// pass `nil` to detach.
    func attach(to socket: SocketIOService?) {
        chatSubscription?.dispose()
        channelSubscription?.dispose()
        chatSubscription = nil
        channelSubscription = nil
        guard let socket else { return }

        // Establish the baseline early so only activity from now on is announced.
        if let key = stateKey { _ = loadState(key) }

        chatSubscription = socket.addChatEventHandler { [weak self] event, _ in
            // Cheap filter off the main thread — this handler sees every streaming token.
            guard let data = event["data"] as? [String: Any],
                  data["type"] as? String == "chat:completion",
                  (data["data"] as? [String: Any])?["done"] as? Bool == true,
                  let chatId = event["chat_id"] as? String, !chatId.isEmpty,
                  !chatId.hasPrefix("channel:"), !chatId.hasPrefix("local:"),
                  !LocalChatOrigin.contains(chatId) else { return }
            Task { @MainActor [weak self] in
                await self?.handleLiveChatFinished(chatId: chatId)
            }
        }

        channelSubscription = socket.addChannelEventHandler { [weak self] event, _ in
            guard let data = event["data"] as? [String: Any],
                  let type = data["type"] as? String,
                  type == "message" || type == "message:update" else { return }
            // Same hop-to-main pattern as ChannelListViewModel; parsing happens on main.
            Task { @MainActor [weak self] in
                self?.routeLiveChannelEvent(event)
            }
        }
    }

    private func routeLiveChannelEvent(_ event: [String: Any]) {
        guard let channelId = event["channel_id"] as? String,
              let data = event["data"] as? [String: Any],
              let type = data["type"] as? String,
              let messageJSON = data["data"] as? [String: Any],
              let message = ChannelMessage.fromJSON(messageJSON) else { return }
        let channel = (event["channel"] as? [String: Any]).flatMap { Channel.fromJSON($0) }
        let eventUserName = (event["user"] as? [String: Any])?["name"] as? String
        Task {
            await handleLiveChannelMessage(
                message, channelId: channelId, isUpdate: type == "message:update",
                channel: channel, eventUserName: eventUserName)
        }
    }

    private func handleLiveChatFinished(chatId: String) async {
        guard Self.externalChatNotificationsEnabled,
              let key = stateKey,
              let api = dependencies?.apiClient,
              dependencies?.activeChatStore.isStreaming(chatId) != true,
              loadState(key).seenChatIds[chatId] == nil,
              !inFlightChatIds.contains(chatId) else { return }

        inFlightChatIds.insert(chatId)
        defer { inFlightChatIds.remove(chatId) }

        // The "done" event can arrive just before the final message is saved, so
        // give the server a moment, and retry once if the reply isn't finished yet.
        for delay in [1.5, 4.0] {
            try? await Task.sleep(for: .seconds(delay))
            guard let conversation = try? await api.getConversation(id: chatId) else { return }
            if await evaluateChat(conversation, key: key) != .pending { return }
        }
    }

    private func handleLiveChannelMessage(
        _ message: ChannelMessage,
        channelId: String,
        isUpdate: Bool,
        channel: Channel?,
        eventUserName: String?
    ) async {
        guard Self.channelNotificationsEnabled,
              let key = stateKey,
              loadState(key).notifiedMessageIds[message.id] == nil else { return }

        // Updates only matter for model replies finishing; ignore edits and old messages.
        if isUpdate && !message.isFromModel { return }
        guard Date().timeIntervalSince(message.createdAt) < stalePendingAge else { return }

        // The user is looking at this channel — nothing to announce.
        if NotificationService.shared.activeChannelId == channelId { return }

        // Live events deliver thread replies on their own — no thread fetch needed.
        let resolution = await resolveChannelMessage(
            message, channelId: channelId, api: nil, eventUserName: eventUserName)
        guard case let .notify(messageId, sender, text) = resolution else { return }

        let title: String = {
            guard let channel else { return sender }
            if channel.type == .dm { return channel.name.isEmpty ? sender : channel.name }
            return "#\(channel.name)"
        }()
        await deliverChannelNotification(
            channelId: channelId, title: title, sender: sender, text: text,
            messageId: messageId, key: key)
    }
}
