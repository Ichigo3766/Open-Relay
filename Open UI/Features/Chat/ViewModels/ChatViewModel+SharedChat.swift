import Foundation

/// Shared-chat helpers: chats opened through a share link or
/// a folder shared with the user belong to someone else.
///
/// - Clone only: the chat is read-only; it can be cloned or forked.
/// - Allow replies (`share_mode == "continue"`): the user can send messages, but
///   only their own messages can be edited, rated, regenerated or stopped, and
///   the owner's chat (title, settings, history) is never saved back.
extension ChatViewModel {

    /// The signed-in user's ID (set by ChatDetailView on appear).
    var viewerUserId: String? { activeChatStoreUserId }

    /// True when the open chat belongs to someone else.
    var isSharedChat: Bool {
        conversation?.isShared(withViewer: viewerUserId) ?? false
    }

    /// True for a shared chat the user can only view (Clone only).
    var isSharedReadOnly: Bool {
        isSharedChat && conversation?.allowsSharedReplies != true
    }

    /// True for a shared chat where the user may reply.
    var isSharedReplyMode: Bool {
        isSharedChat && conversation?.allowsSharedReplies == true
    }

    /// Whether the signed-in user wrote / started this message. In the user's
    /// own chats every message counts as theirs.
    func isOwnMessage(_ message: ChatMessage) -> Bool {
        guard isSharedChat else { return true }
        let author = message.authorId ?? conversation?.ownerUserId
        return author == viewerUserId
    }

    /// Display name of a user message's author in shared chats (nil for own messages).
    func authorName(of message: ChatMessage) -> String? {
        guard isSharedChat, message.role == .user, !isOwnMessage(message) else { return nil }
        let name = message.authorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? String(localized: "Unknown User") : name
    }

    /// Clones the shared chat into the user's own chats from the viewed message,
    /// then opens the copy.
    func cloneSharedChat() async {
        guard let current = conversation?.messages.last?.id else { return }
        await forkChat(messageId: current)
    }

    // MARK: - Live chat room (typing + live replies from other people)

    /// Joins `chat:{id}` so replies and typing from everyone the chat is shared
    /// with arrive live. Only needed for shared chats; harmless otherwise.
    func joinSharedChatRoomIfNeeded() {
        guard isSharedChat, let chatId = conversationId ?? conversation?.id,
              !chatId.hasPrefix("local:"), let socket = socketService, socket.isConnected else { return }
        guard joinedChatRoomId != chatId else { return }
        leaveSharedChatRoom()
        socket.emit("events:chat", data: ["chat_id": chatId, "data": ["type": "join"]])
        joinedChatRoomId = chatId
    }

    func leaveSharedChatRoom() {
        guard let joined = joinedChatRoomId else { return }
        emitTyping(false)
        socketService?.emit("events:chat", data: ["chat_id": joined, "data": ["type": "leave"]])
        joinedChatRoomId = nil
        typingUsers = []
    }

    /// Tells others in a shared chat that the user is typing (throttled to 2s, like the web).
    func emitTyping(_ typing: Bool) {
        guard isSharedReplyMode, let chatId = joinedChatRoomId, let socket = socketService, socket.isConnected else { return }
        let now = Date()
        if typing {
            if let last = lastTypingEmit, now.timeIntervalSince(last) < 2 { return }
            lastTypingEmit = now
        } else {
            guard lastTypingEmit != nil else { return }
            lastTypingEmit = nil
        }
        socket.emit("events:chat", data: [
            "chat_id": chatId,
            "data": ["type": "typing", "data": ["typing": typing]],
        ])
    }

    /// Handles a `typing` event from another person in the chat.
    func handleTypingEvent(_ event: [String: Any], typing: Bool) {
        guard isSharedChat || conversation?.allowsSharedReplies == true else { return }
        let sender = event["user"] as? [String: Any]
        guard let senderId = sender?["id"] as? String ?? event["user_id"] as? String,
              senderId != viewerUserId else { return }
        let name = sender?["name"] as? String ?? ""
        typingClearTasks[senderId]?.cancel()
        if typing {
            if !typingUsers.contains(where: { $0.id == senderId }) {
                typingUsers.append(TypingUser(id: senderId, name: name))
            }
            // Drop the indicator if no update arrives for 5s.
            typingClearTasks[senderId] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.typingUsers.removeAll { $0.id == senderId }
            }
        } else {
            typingUsers.removeAll { $0.id == senderId }
        }
    }
}
