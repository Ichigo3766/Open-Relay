import Foundation
import os.log

// MARK: - Background check + foreground catch-up

extension ExternalActivityNotifier {

    /// Marks what's already on the server as seen when the user opens the app,
    /// so a later background check doesn't notify about it. Debounced.
    func catchUpOnForeground() {
        guard Date().timeIntervalSince(lastCatchUp) > 30 else { return }
        lastCatchUp = Date()
        Task { await catchUp() }
    }

    private func catchUp() async {
        guard let key = stateKey, let api = dependencies?.apiClient,
              api.network.authToken != nil else { return }
        mutateState(key) { $0.channelFloor = Date().timeIntervalSince1970 }

        guard let summaries = try? await api.getRecentConversationSummaries() else { return }
        for summary in chatCandidates(summaries, key: key) {
            guard let conversation = try? await api.getConversation(id: summary.id) else { continue }
            // Finished chats are already visible in the app — don't announce them later.
            // Unfinished ones stay eligible so the user still hears when they complete.
            if chatReply(conversation) != nil { markChatSeen(conversation.id, key: key) }
        }
    }

    /// Called from the background app-refresh task.
    func performBackgroundCheck() async {
        guard !isCheckingInBackground else { return }
        isCheckingInBackground = true
        defer { isCheckingInBackground = false }

        // On a background launch the container is created moments after we wake.
        var waited = 0
        while dependencies?.apiClient == nil && waited < 30 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        guard let api = dependencies?.apiClient,
              api.network.authToken != nil,
              let key = stateKey else {
            logger.info("Background check skipped — not signed in or keychain locked")
            return
        }

        await checkChats(api: api, key: key)
        await checkChannels(api: api, key: key)
    }

    private func checkChats(api: APIClient, key: String) async {
        guard Self.externalChatNotificationsEnabled else { return }
        do {
            let summaries = try await api.getRecentConversationSummaries()
            for summary in chatCandidates(summaries, key: key) {
                guard let conversation = try? await api.getConversation(id: summary.id) else { continue }
                _ = await evaluateChat(conversation, key: key)
            }
        } catch {
            logger.warning("Background chat check failed: \(error.localizedDescription)")
        }
    }

    private func checkChannels(api: APIClient, key: String) async {
        guard Self.channelNotificationsEnabled else { return }
        do {
            for channel in try await api.getChannels() {
                guard let last = channel.lastMessageAt?.timeIntervalSince1970,
                      last > channelCursor(channel.id, key: key) else { continue }
                await processChannel(channel, api: api, key: key)
            }
        } catch {
            logger.warning("Background channel check failed: \(error.localizedDescription)")
        }
    }

    private func channelCursor(_ channelId: String, key: String) -> Double {
        let state = loadState(key)
        return max(state.channelCursors[channelId] ?? 0, state.channelFloor, state.baseline)
    }

    private func processChannel(_ channel: Channel, api: APIClient, key: String) async {
        guard let messages = try? await api.getChannelMessages(id: channel.id, limit: 20) else { return }
        let cursor = channelCursor(channel.id, key: key)
        let now = Date().timeIntervalSince1970
        let fresh = messages
            .filter { $0.createdAt.timeIntervalSince1970 > cursor }
            .sorted { $0.createdAt < $1.createdAt }

        var newCursor = cursor
        var toDeliver: [(messageId: String, sender: String, text: String)] = []
        for message in fresh {
            let created = message.createdAt.timeIntervalSince1970
            let resolution = await resolveChannelMessage(
                message, channelId: channel.id, api: api, eventUserName: nil)
            if case .pending = resolution, now - created < stalePendingAge {
                // Reply still generating — stop here so the next check picks it up.
                break
            }
            if case let .notify(messageId, sender, text) = resolution {
                toDeliver.append((messageId, sender, text))
            }
            newCursor = created
        }

        let advanced = newCursor
        mutateState(key) { $0.channelCursors[channel.id] = advanced }

        // Only the latest few per channel, so a busy channel doesn't flood the screen.
        let title = channelTitle(channel)
        for item in toDeliver.suffix(3) {
            await deliverChannelNotification(
                channelId: channel.id, title: title, sender: item.sender, text: item.text,
                messageId: item.messageId, key: key)
        }
    }
}
