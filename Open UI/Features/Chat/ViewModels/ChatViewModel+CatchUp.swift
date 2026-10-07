import Foundation
import os.log
import SwiftUI

// MARK: - Live Cross-Device Catch-Up
//
// Keeps a chat live across devices, following what Open WebUI's own web client does
// (`Chat.svelte`: `handleSocketConnect` + the `chat:active` handler):
//
//  • `GET /api/v1/chats/{id}` already folds the generation's CURRENT partial reply into
//    the message and marks it `done: false` (`overlay_response_streams`), so one fetch
//    shows exactly what the other device is showing right now.
//  • `GET /api/tasks/chat/{id}` lists generations still running for the chat. Empty means
//    nothing is running, so a message left at `done: false` is stale.
//  • Token events go to every device in the user's `user:{id}` room, so once this device's
//    socket is back we simply keep receiving them.
//
// `catchUpWithServer` is the single entry point used on foreground return, socket
// reconnect and chat events. It replaces "sync after 10 s, then wait for the next token".

/// Why a catch-up was requested (for logs only).
enum CatchUpReason: String {
    case foreground, socketReconnect, chatActive, chatOpened
}

extension ChatViewModel {

    /// Brings this chat fully up to date and, when another device is still generating,
    /// attaches to that reply as a live stream.
    ///
    /// Safe to call often: it returns early while this device is streaming its own reply,
    /// and the fast path in `adoptServerMessages` makes an unchanged chat a no-op.
    func catchUpWithServer(reason: CatchUpReason) async {
        guard !selfInitiatedStream, let chatId = conversationId ?? conversation?.id,
              !chatId.hasPrefix("local:"), let manager else { return }
        // A reply this device is producing itself is already live.
        if isStreaming && !isExternallyStreaming { return }

        // Be subscribed before fetching, so no token can slip between the two.
        if let socket = socketService {
            _ = await socket.ensureConnected(timeout: 1.5)
            if passiveSubscription == nil || reason == .socketReconnect || reason == .foreground {
                startPassiveSocketListener()
            }
        }

        // The chat (with the live partial reply) and the running generations, in parallel.
        async let fetchedChat = try? manager.fetchConversation(id: chatId)
        async let fetchedTasks = try? manager.apiClient.getTasksForChat(chatId: chatId)
        guard let serverChat = await fetchedChat else { return }
        let runningTasks = await fetchedTasks
        lastSyncTime = Date()
        guard !serverChat.messages.isEmpty else { return }

        let hadMessages = !(conversation?.messages.isEmpty ?? true)
        let countBefore = conversation?.messages.count ?? 0

        // The last assistant reply on the server, and whether it is unfinished there.
        let serverLast = serverChat.messages.last(where: { $0.role == .assistant })
        let serverSaysGenerating = serverLast?.isStreaming == true
        // `nil` means the task check failed: don't conclude anything from it.
        let generationRunning: Bool? = runningTasks.map { !$0.isEmpty }

        // 1. Apply new/changed messages in one animated pass.
        withAnimation(MicroAnimation.glide) {
            adoptServerMessages(serverConversation: serverChat)
        }

        // 2. Decide what to do with the last reply.
        resolveLastReply(serverLast, serverSaysGenerating: serverSaysGenerating,
                         generationRunning: generationRunning, reason: reason)

        // 3. Tell the view something arrived from another device, so it can glide there.
        let countAfter = conversation?.messages.count ?? 0
        if hadMessages && (countAfter > countBefore || serverSaysGenerating) {
            remoteScrollPending = true
            remoteUpdateToken &+= 1
        }
    }

    private func resolveLastReply(_ serverLast: ChatMessage?, serverSaysGenerating: Bool,
                                  generationRunning: Bool?, reason: CatchUpReason) {
        guard let serverLast else { return }
        if serverSaysGenerating, generationRunning != false {
            attachToLiveReply(serverLast, reason: reason)
        } else if serverSaysGenerating {
            // The generation ended while we were away; only the flag is stale. Re-fetch
            // once for the final content, files, sources and follow-ups.
            logger.info("Catch-up(\(reason.rawValue)): reply \(serverLast.id) ended while away — final sync")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                await self?.syncWithServer(force: true)
            }
        } else if isExternallyStreaming {
            // We were following a reply that has since finished elsewhere.
            finishExternalFollow(with: serverLast)
        }
    }
}
