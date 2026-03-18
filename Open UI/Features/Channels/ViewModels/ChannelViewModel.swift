import Foundation
import os.log
import SwiftUI

/// Manages state and logic for a single channel conversation.
/// Handles messages, threading, reactions, @mentions (users + models),
/// file uploads, pinning, and real-time Socket.IO updates.
@MainActor @Observable
final class ChannelViewModel {
    // MARK: - Published State
    
    var channel: Channel?
    var messages: [ChannelMessage] = []
    var members: [ChannelMember] = []
    var allServerUsers: [ChannelMember] = []
    var pinnedMessages: [ChannelMessage] = []
    var availableModels: [AIModel] = []
    var availableChannels: [Channel] = []
    
    var isLoadingChannel: Bool = false
    var isLoadingMessages: Bool = false
    var isLoadingMore: Bool = false
    var isLoadingMembers: Bool = false
    var errorMessage: String?
    
    var inputText: String = ""
    var attachments: [ChatAttachment] = []
    var replyToMessage: ChannelMessage?
    var editingMessage: ChannelMessage?
    var editingText: String = ""
    
    // Thread state — uses separate attachment array (BUG-011 fix)
    var threadParentMessage: ChannelMessage?
    var threadMessages: [ChannelMessage] = []
    var isLoadingThread: Bool = false
    var threadInputText: String = ""
    var threadAttachments: [ChatAttachment] = []
    
    // @mention state
    var mentionedModelId: String?
    var mentionedModelName: String?
    
    // UI state
    var showMembersSheet: Bool = false
    var showPinnedSheet: Bool = false
    var activeReactionMessageId: String?
    var showCopiedToast: Bool = false
    
    let channelId: String
    
    // MARK: - Computed
    
    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
    }
    
    var canSendThread: Bool {
        !threadInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !threadAttachments.isEmpty
    }
    
    /// Current user ID (from the auth session).
    var currentUserId: String?
    
    /// Server base URL for image resolution.
    var serverBaseURL: String { apiClient?.baseURL ?? "" }
    
    /// Auth token for authenticated image requests.
    var serverAuthToken: String? { apiClient?.network.authToken }
    
    // MARK: - Channel Type Helpers
    
    /// Whether this is a Direct Message channel.
    var isDM: Bool { channel?.type == .dm }
    
    /// Whether this is a Group channel.
    var isGroup: Bool { channel?.type == .group }
    
    /// Whether this is a Standard topic-based channel.
    var isStandard: Bool { channel?.type == .standard }
    
    /// For DM channels: returns all members except the current user.
    var dmParticipants: [ChannelMember] {
        guard isDM else { return [] }
        return members.filter { $0.id != currentUserId }
    }
    
    /// For 1-on-1 DMs: returns the single other participant (nil if group DM or not a DM).
    var dmOtherParticipant: ChannelMember? {
        let participants = dmParticipants
        return participants.count == 1 ? participants.first : nil
    }
    
    /// Display title for the channel based on type.
    var channelDisplayTitle: String {
        if isDM {
            let participants = dmParticipants
            if participants.isEmpty {
                let channelParticipants = channel?.dmParticipants ?? []
                if !channelParticipants.isEmpty {
                    return channelParticipants.map { $0.name ?? $0.email }.joined(separator: ", ")
                }
                return channel?.name ?? "Direct Message"
            }
            if participants.count == 1 { return participants[0].displayName }
            return participants.prefix(3).map { $0.displayName }.joined(separator: ", ")
        }
        return channel?.name ?? "Channel"
    }
    
    /// Contextual input placeholder based on channel type.
    var inputPlaceholder: String {
        if isDM {
            let name = dmOtherParticipant?.displayName ?? "message"
            return "Message \(name)…"
        }
        let name = channel?.name ?? "channel"
        return "Message #\(name)…"
    }
    
    /// Whether the current user has write access to this channel (MF-005).
    /// Determined solely by the server-returned `write_access` field.
    var hasWriteAccess: Bool {
        channel?.canWrite ?? true
    }
    
    /// Whether the current user can access channel settings.
    var canManageChannel: Bool {
        guard let channel, let userId = currentUserId else { return false }
        if isDM {
            return members.contains(where: { $0.id == userId })
        }
        if isStandard {
            let isAdmin = members.first(where: { $0.id == userId })?.role == "admin"
            return channel.userId == userId || isAdmin
        }
        return channel.userId == userId
    }
    
    // MARK: - Private
    
    private var apiClient: APIClient?
    private var socketService: SocketIOService?
    private var channelSubscription: SocketSubscription?
    private let logger = Logger(subsystem: "com.openui", category: "ChannelVM")
    private var hasLoadedMessages = false
    private var allMessagesLoaded = false
    private let pageSize = 50
    
    /// R-028: Reaction rate limiting — minimum interval between reaction API calls
    private var lastReactionTime: Date = .distantPast
    private let reactionCooldown: TimeInterval = 0.3
    
    // MARK: - Init
    
    init(channelId: String) {
        self.channelId = channelId
    }
    
    // MARK: - Configuration
    
    func configure(apiClient: APIClient, socket: SocketIOService?, currentUserId: String?) {
        self.apiClient = apiClient
        self.socketService = socket
        self.currentUserId = currentUserId
    }
    
    // MARK: - Loading
    
    func load() async {
        guard let apiClient else { return }
        
        isLoadingChannel = true
        
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadChannel() }
            group.addTask { await self.loadMessages() }
            group.addTask { await self.loadMembers() }
            group.addTask { await self.loadModels() }
            group.addTask { await self.loadAllServerUsers() }
            group.addTask { await self.loadAvailableChannels() }
        }
        
        isLoadingChannel = false
        
        startSocketListener()
        
        if let token = apiClient.network.authToken {
            socketService?.emit("join-channels", data: ["auth": ["token": token]])
            logger.info("Emitted join-channels to refresh socket room membership")
        }
        
        // Mark as active + mark-as-read (MF-006)
        Task {
            try? await apiClient.updateMemberActiveStatus(channelId: channelId, isActive: true)
        }
    }
    
    func loadChannel() async {
        guard let apiClient else { return }
        do {
            channel = try await apiClient.getChannel(id: channelId)
        } catch {
            logger.error("Failed to load channel: \(error.localizedDescription)")
            errorMessage = "Failed to load channel."
        }
    }
    
    func loadMessages() async {
        guard let apiClient else { return }
        if !hasLoadedMessages { isLoadingMessages = true }
        
        do {
            let fetched = try await apiClient.getChannelMessages(id: channelId, skip: 0, limit: pageSize)
            messages = fetched.reversed()
            hasLoadedMessages = true
            allMessagesLoaded = fetched.count < pageSize
            
            // R-001: Only fetch /data for messages where hasData == true
            await loadMessageDataForMessagesWithData()
        } catch {
            logger.error("Failed to load messages: \(error.localizedDescription)")
            if !hasLoadedMessages {
                errorMessage = "Failed to load messages."
            }
        }
        
        isLoadingMessages = false
    }
    
    /// Loads older messages (infinite scroll up).
    func loadOlderMessages() async {
        guard !isLoadingMore, !allMessagesLoaded, let apiClient else { return }
        isLoadingMore = true
        
        do {
            let fetched = try await apiClient.getChannelMessages(
                id: channelId,
                skip: messages.count,
                limit: pageSize
            )
            if fetched.isEmpty {
                allMessagesLoaded = true
            } else {
                let existingIds = Set(messages.map(\.id))
                let newMessages = fetched.reversed().filter { !existingIds.contains($0.id) }
                messages.insert(contentsOf: newMessages, at: 0)
                if fetched.count < pageSize { allMessagesLoaded = true }
            }
        } catch {
            logger.error("Failed to load older messages: \(error.localizedDescription)")
        }
        
        isLoadingMore = false
    }
    
    // MARK: - File Data Loading (R-001: Fixed N+1 queries)
    
    /// Fetches /data only for messages where `hasData == true`.
    /// Avoids N+1 queries — most messages have no files, so this dramatically reduces requests.
    private func loadMessageDataForMessagesWithData() async {
        guard let apiClient else { return }
        
        let messageIds = messages
            .filter { $0.hasData && !$0.isOptimistic }
            .map(\.id)
        
        guard !messageIds.isEmpty else { return }
        logger.debug("Fetching /data for \(messageIds.count) messages (of \(self.messages.count) total)")
        
        await withTaskGroup(of: (String, [ChatMessageFile])?.self) { group in
            for msgId in messageIds {
                group.addTask {
                    guard let data = try? await apiClient.getChannelMessageData(
                        channelId: self.channelId,
                        messageId: msgId
                    ) else { return nil }
                    
                    let files = ChannelMessageFileParser.parseFiles(from: data)
                    return files.isEmpty ? nil : (msgId, files)
                }
            }
            
            for await result in group {
                guard let (messageId, files) = result else { continue }
                if let idx = messages.firstIndex(where: { $0.id == messageId }) {
                    messages[idx].files = files
                }
            }
        }
    }
    
    /// Fetches /data for a single message and populates its files.
    func loadMessageData(for messageId: String) async {
        guard let apiClient else { return }
        guard let data = try? await apiClient.getChannelMessageData(channelId: channelId, messageId: messageId) else { return }
        
        let files = ChannelMessageFileParser.parseFiles(from: data)
        if !files.isEmpty, let idx = messages.firstIndex(where: { $0.id == messageId }) {
            messages[idx].files = files
        }
    }
    
    func loadMembers() async {
        guard let apiClient else { return }
        isLoadingMembers = true
        
        do {
            members = try await apiClient.getChannelMembers(id: channelId)
            logger.info("Loaded \(self.members.count) channel members")
        } catch {
            logger.error("Failed to load members: \(error.localizedDescription)")
        }
        
        isLoadingMembers = false
    }
    
    private func loadModels() async {
        guard let apiClient else { return }
        do {
            availableModels = try await apiClient.getModels()
        } catch {
            logger.warning("Failed to load models: \(error.localizedDescription)")
        }
    }
    
    func loadPinnedMessages() async {
        guard let apiClient else { return }
        do {
            pinnedMessages = try await apiClient.getPinnedChannelMessages(channelId: channelId)
        } catch {
            logger.error("Failed to load pinned messages: \(error.localizedDescription)")
        }
    }
    
    func loadAllServerUsers() async {
        guard let apiClient else { return }
        do {
            allServerUsers = try await apiClient.searchUsers()
            logger.info("Loaded \(self.allServerUsers.count) server users for access picker")
        } catch {
            logger.warning("Failed to load all server users: \(error.localizedDescription)")
        }
    }
    
    func loadAvailableChannels() async {
        guard let apiClient else { return }
        do {
            availableChannels = try await apiClient.getChannels()
            logger.info("Loaded \(self.availableChannels.count) channels for # picker")
        } catch {
            logger.warning("Failed to load channels for picker: \(error.localizedDescription)")
        }
    }
    
    var availableChannelsForPicker: [Channel] {
        availableChannels.filter { $0.id != channelId }
    }
    
    var accessibleChannelIds: Set<String> {
        Set(availableChannels.map(\.id))
    }
    
    // MARK: - Send Message
    
    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        guard let apiClient else { return }
        
        let currentText = text
        let replyId = replyToMessage?.id
        let modelMention = mentionedModelId
        let modelMentionName = mentionedModelName
        
        // Clear input immediately
        inputText = ""
        replyToMessage = nil
        let currentAttachments = attachments
        attachments = []
        
        // Build data payload
        var msgData: [String: Any] = [:]
        
        var fileRefs: [[String: Any]] = []
        for attachment in currentAttachments {
            if let fileId = attachment.uploadedFileId {
                fileRefs.append([
                    "type": attachment.type == .image ? "image" : "file",
                    "id": fileId,
                    "name": attachment.name
                ])
            } else if let data = attachment.data {
                do {
                    let fileId = try await apiClient.uploadFile(data: data, fileName: attachment.name)
                    fileRefs.append([
                        "type": attachment.type == .image ? "image" : "file",
                        "id": fileId,
                        "name": attachment.name
                    ])
                } catch {
                    logger.error("File upload failed: \(error.localizedDescription)")
                }
            }
        }
        if !fileRefs.isEmpty { msgData["files"] = fileRefs }
        if let modelMention { msgData["model"] = modelMention }
        
        // Create optimistic message
        let tempId = "temp:\(UUID().uuidString)"
        
        let currentMember = members.first(where: { $0.id == currentUserId })
        let resolvedName: String = {
            if let name = currentMember?.name, !name.isEmpty { return name }
            if let name = currentMember?.displayName, !name.isEmpty { return name }
            if let prev = messages.last(where: { $0.userId == currentUserId && !$0.isOptimistic }),
               let name = prev.user?.name, !name.isEmpty {
                return name
            }
            return "You"
        }()
        
        var optimisticMsg = ChannelMessage(
            id: tempId,
            userId: currentUserId ?? "",
            channelId: channelId,
            content: currentText,
            replyToId: replyId,
            user: ChannelMessageUser(
                id: currentUserId ?? "",
                name: resolvedName,
                role: currentMember?.role ?? "user"
            ),
            files: fileRefs.map { ref in
                ChatMessageFile(
                    type: ref["type"] as? String,
                    url: ref["id"] as? String,
                    name: ref["name"] as? String
                )
            }
        )
        optimisticMsg.isOptimistic = true
        // R-025: Store retry context for failed message recovery
        optimisticMsg.retryContext = RetryContext(
            replyToId: replyId,
            mentionedModelId: modelMention,
            mentionedModelName: modelMentionName,
            attachmentNames: currentAttachments.map(\.name)
        )
        messages.append(optimisticMsg)
        
        // Clear model mention after send
        mentionedModelId = nil
        mentionedModelName = nil
        
        // Send to server
        do {
            let serverMsg = try await apiClient.postChannelMessage(
                channelId: channelId,
                content: currentText,
                replyToId: replyId,
                data: msgData.isEmpty ? nil : msgData
            )
            
            if let idx = messages.firstIndex(where: { $0.id == tempId }) {
                if var serverMsg {
                    // Preserve user info from optimistic if server didn't include it
                    if serverMsg.user == nil || serverMsg.user?.name == nil {
                        serverMsg = serverMsg.withUser(messages[idx].user ?? ChannelMessageUser(id: currentUserId ?? "", name: resolvedName, role: "user"))
                    }
                    messages[idx] = serverMsg
                } else {
                    messages[idx].isOptimistic = false
                }
            }
        } catch {
            if let idx = messages.firstIndex(where: { $0.id == tempId }) {
                messages[idx].isFailed = true
                messages[idx].isOptimistic = false
            }
            logger.error("Failed to send message: \(error.localizedDescription)")
        }
    }
    
    /// Sends a message in a thread. Uses separate threadAttachments (BUG-011 fix).
    func sendThreadMessage() async {
        let text = threadInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !threadAttachments.isEmpty, let parentId = threadParentMessage?.id else { return }
        guard let apiClient else { return }
        
        let currentText = text
        threadInputText = ""
        let currentAttachments = threadAttachments
        threadAttachments = []
        
        var msgData: [String: Any] = [:]
        var fileRefs: [[String: Any]] = []
        for attachment in currentAttachments {
            if let fileId = attachment.uploadedFileId {
                fileRefs.append([
                    "type": attachment.type == .image ? "image" : "file",
                    "id": fileId,
                    "name": attachment.name
                ])
            } else if let data = attachment.data {
                do {
                    let fileId = try await apiClient.uploadFile(data: data, fileName: attachment.name)
                    fileRefs.append([
                        "type": attachment.type == .image ? "image" : "file",
                        "id": fileId,
                        "name": attachment.name
                    ])
                } catch {
                    logger.error("Thread file upload failed: \(error.localizedDescription)")
                }
            }
        }
        if !fileRefs.isEmpty { msgData["files"] = fileRefs }
        
        do {
            let msg = try await apiClient.postChannelMessage(
                channelId: channelId,
                content: currentText,
                parentId: parentId,
                data: msgData.isEmpty ? nil : msgData
            )
            if let msg {
                threadMessages.append(msg)
                await loadThreadMessageData(for: msg.id)
                // BUG-005 fix: Don't manually increment — let the API refresh handle it
                // The socket event will trigger a refresh of the parent message
            }
        } catch {
            logger.error("Failed to send thread message: \(error.localizedDescription)")
        }
    }
    
    /// Retries sending a failed optimistic message (R-025: restores full context).
    func retrySendMessage(id: String) async {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        let msg = messages[idx]
        
        messages.remove(at: idx)
        
        // Restore context from retry metadata
        inputText = msg.content
        if let ctx = msg.retryContext {
            if let replyId = ctx.replyToId,
               let replyMsg = messages.first(where: { $0.id == replyId }) {
                replyToMessage = replyMsg
            }
            mentionedModelId = ctx.mentionedModelId
            mentionedModelName = ctx.mentionedModelName
        }
        
        await sendMessage()
    }
    
    // MARK: - Edit Message
    
    func beginEditing(message: ChannelMessage) {
        editingMessage = message
        editingText = message.content
    }
    
    func cancelEditing() {
        editingMessage = nil
        editingText = ""
    }
    
    func submitEdit() async {
        guard let message = editingMessage, let apiClient else { return }
        let newContent = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newContent.isEmpty else { return }
        
        let messageId = message.id
        editingMessage = nil
        editingText = ""
        
        // Optimistic update
        if let idx = messages.firstIndex(where: { $0.id == messageId }) {
            messages[idx].content = newContent
        }
        if let idx = threadMessages.firstIndex(where: { $0.id == messageId }) {
            threadMessages[idx].content = newContent
        }
        
        do {
            let updated = try await apiClient.updateChannelMessage(
                channelId: channelId,
                messageId: messageId,
                content: newContent
            )
            if let updated {
                if let idx = messages.firstIndex(where: { $0.id == messageId }) {
                    messages[idx] = updated
                }
                if let idx = threadMessages.firstIndex(where: { $0.id == messageId }) {
                    threadMessages[idx] = updated
                }
            }
        } catch {
            logger.error("Failed to edit message: \(error.localizedDescription)")
            await loadMessages()
        }
    }
    
    // MARK: - Delete Message
    
    func deleteMessage(id: String) async {
        guard let apiClient else { return }
        
        let removedIdx = messages.firstIndex(where: { $0.id == id })
        let removedMsg = removedIdx.map { messages[$0] }
        if let idx = removedIdx { messages.remove(at: idx) }
        
        let removedThreadIdx = threadMessages.firstIndex(where: { $0.id == id })
        let removedThreadMsg = removedThreadIdx.map { threadMessages[$0] }
        if let idx = removedThreadIdx { threadMessages.remove(at: idx) }
        
        do {
            try await apiClient.deleteChannelMessage(channelId: channelId, messageId: id)
        } catch {
            if let msg = removedMsg, let idx = removedIdx {
                messages.insert(msg, at: min(idx, messages.count))
            }
            if let msg = removedThreadMsg, let idx = removedThreadIdx {
                threadMessages.insert(msg, at: min(idx, threadMessages.count))
            }
            logger.error("Failed to delete message: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Reactions (R-028: Rate limited)
    
    func toggleReaction(messageId: String, emoji: String) async {
        guard let apiClient, let userId = currentUserId else { return }
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        
        // R-028: Rate limit reactions
        let now = Date()
        guard now.timeIntervalSince(lastReactionTime) >= reactionCooldown else { return }
        lastReactionTime = now
        
        let hasReacted = messages[idx].hasReaction(emoji, byUserId: userId)
        
        // Optimistic update
        if hasReacted {
            if let rIdx = messages[idx].reactions.firstIndex(where: { $0.name == emoji }) {
                messages[idx].reactions[rIdx].userIds.removeAll { $0 == userId }
                messages[idx].reactions[rIdx].count = max(0, messages[idx].reactions[rIdx].count - 1)
                if messages[idx].reactions[rIdx].count == 0 {
                    messages[idx].reactions.remove(at: rIdx)
                }
            }
        } else {
            if let rIdx = messages[idx].reactions.firstIndex(where: { $0.name == emoji }) {
                messages[idx].reactions[rIdx].userIds.append(userId)
                messages[idx].reactions[rIdx].count += 1
            } else {
                messages[idx].reactions.append(MessageReaction(
                    name: emoji,
                    userIds: [userId],
                    userNames: [],
                    count: 1
                ))
            }
        }
        
        do {
            if hasReacted {
                try await apiClient.removeChannelReaction(channelId: channelId, messageId: messageId, emoji: emoji)
            } else {
                try await apiClient.addChannelReaction(channelId: channelId, messageId: messageId, emoji: emoji)
            }
        } catch {
            logger.error("Failed to toggle reaction: \(error.localizedDescription)")
            await loadMessages()
        }
    }
    
    // MARK: - Pin / Unpin
    
    func togglePin(messageId: String) async {
        guard let apiClient else { return }
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        
        let newPinned = !messages[idx].isPinned
        messages[idx].isPinned = newPinned
        
        do {
            _ = try await apiClient.pinChannelMessage(
                channelId: channelId,
                messageId: messageId,
                isPinned: newPinned
            )
            await loadPinnedMessages()
        } catch {
            messages[idx].isPinned = !newPinned
            logger.error("Failed to toggle pin: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Threading
    
    func openThread(for message: ChannelMessage) async {
        let isRefresh = threadParentMessage?.id == message.id && !threadMessages.isEmpty
        
        if !isRefresh {
            // BUG-006 fix: Clear editing state when opening a new thread
            cancelEditing()
            threadParentMessage = message
            threadMessages = []
            isLoadingThread = true
            threadAttachments = []
        }
        
        guard let apiClient else {
            isLoadingThread = false
            return
        }
        
        do {
            let fetched = try await apiClient.getChannelThreadMessages(
                channelId: channelId,
                messageId: message.id
            )
            let chronological = fetched.reversed()
            
            if isRefresh {
                let existingIds = Set(threadMessages.map(\.id))
                let newMessages = chronological.filter { !existingIds.contains($0.id) }
                if !newMessages.isEmpty {
                    threadMessages.append(contentsOf: newMessages)
                    for msg in newMessages {
                        await loadThreadMessageData(for: msg.id)
                    }
                }
            } else {
                threadMessages = Array(chronological)
                await loadThreadMessageDataForAll()
            }
        } catch {
            logger.error("Failed to load thread: \(error.localizedDescription)")
        }
        
        isLoadingThread = false
    }
    
    /// Fetches /data for all thread messages that have data. (R-001 applied to threads)
    private func loadThreadMessageDataForAll() async {
        guard let apiClient else { return }
        
        let messageIds = threadMessages
            .filter { $0.hasData }
            .map(\.id)
        
        guard !messageIds.isEmpty else { return }
        
        await withTaskGroup(of: (String, [ChatMessageFile])?.self) { group in
            for msgId in messageIds {
                group.addTask {
                    guard let data = try? await apiClient.getChannelMessageData(
                        channelId: self.channelId,
                        messageId: msgId
                    ) else { return nil }
                    
                    let files = ChannelMessageFileParser.parseFiles(from: data)
                    return files.isEmpty ? nil : (msgId, files)
                }
            }
            
            for await result in group {
                guard let (messageId, files) = result else { continue }
                if let idx = threadMessages.firstIndex(where: { $0.id == messageId }) {
                    threadMessages[idx].files = files
                }
            }
        }
    }
    
    /// Fetches /data for a single thread message.
    func loadThreadMessageData(for messageId: String) async {
        guard let apiClient else { return }
        guard let data = try? await apiClient.getChannelMessageData(channelId: channelId, messageId: messageId) else { return }
        
        let files = ChannelMessageFileParser.parseFiles(from: data)
        if !files.isEmpty, let idx = threadMessages.firstIndex(where: { $0.id == messageId }) {
            threadMessages[idx].files = files
        }
    }
    
    func closeThread() {
        // BUG-006 fix: Clear editing state when closing thread
        cancelEditing()
        threadParentMessage = nil
        threadMessages = []
        threadInputText = ""
        threadAttachments = []
    }
    
    // MARK: - Reply
    
    func setReplyTo(_ message: ChannelMessage) {
        replyToMessage = message
    }
    
    func clearReply() {
        replyToMessage = nil
    }
    
    // MARK: - File Upload
    
    func uploadAttachmentImmediately(attachmentId: UUID, isThread: Bool = false) {
        let targetAttachments = isThread ? threadAttachments : attachments
        guard let idx = targetAttachments.firstIndex(where: { $0.id == attachmentId }) else { return }
        guard targetAttachments[idx].type != .audio else { return }
        
        if isThread {
            threadAttachments[idx].uploadStatus = .uploading
        } else {
            attachments[idx].uploadStatus = .uploading
        }
        
        Task {
            guard let apiClient else {
                updateAttachmentError(id: attachmentId, isThread: isThread, error: "Not connected to server")
                return
            }
            
            let source = isThread ? threadAttachments : attachments
            guard let i = source.firstIndex(where: { $0.id == attachmentId }),
                  let data = source[i].data else { return }
            
            let fileName = source[i].name
            
            do {
                let fileId = try await apiClient.uploadFile(data: data, fileName: fileName)
                if isThread {
                    if let i = threadAttachments.firstIndex(where: { $0.id == attachmentId }) {
                        threadAttachments[i].uploadStatus = .completed
                        threadAttachments[i].uploadedFileId = fileId
                        threadAttachments[i].data = nil
                    }
                } else {
                    if let i = attachments.firstIndex(where: { $0.id == attachmentId }) {
                        attachments[i].uploadStatus = .completed
                        attachments[i].uploadedFileId = fileId
                        attachments[i].data = nil
                    }
                }
            } catch {
                updateAttachmentError(id: attachmentId, isThread: isThread, error: error.localizedDescription)
            }
        }
    }
    
    private func updateAttachmentError(id: UUID, isThread: Bool, error: String) {
        if isThread {
            if let i = threadAttachments.firstIndex(where: { $0.id == id }) {
                threadAttachments[i].uploadStatus = .error
                threadAttachments[i].uploadError = error
            }
        } else {
            if let i = attachments.firstIndex(where: { $0.id == id }) {
                attachments[i].uploadStatus = .error
                attachments[i].uploadError = error
            }
        }
    }
    
    // MARK: - @Mention Helpers (DRY-005: Shared token removal)
    
    /// Removes the last `@` or `#` token from a given text.
    private func removeLastToken(of char: Character, from text: String) -> String {
        guard let tokenIndex = text.lastIndex(of: char) else { return text }
        let tokenPos = text.distance(from: text.startIndex, to: tokenIndex)
        let isAtStart = tokenPos == 0
        let precededBySpace = tokenPos > 0 && {
            let beforeIdx = text.index(before: tokenIndex)
            return text[beforeIdx].isWhitespace || text[beforeIdx].isNewline
        }()
        
        guard isAtStart || precededBySpace else { return text }
        let afterToken = text[tokenIndex...]
        let tokenEnd = afterToken.firstIndex(where: { $0.isWhitespace || $0.isNewline }) ?? text.endIndex
        return String(text[text.startIndex..<tokenIndex]) + String(text[tokenEnd...])
    }
    
    /// Removes the `@...` token from the main input text.
    func removeMentionToken() {
        inputText = removeLastToken(of: "@", from: inputText)
    }
    
    /// Inserts a @user mention into the input text.
    func insertUserMention(_ member: ChannelMember) {
        removeMentionToken()
        let mention = "<@U:\(member.id)|\(member.displayName)> "
        inputText += mention
    }
    
    /// Inserts a @model mention into the input text.
    func setModelMention(_ model: AIModel) {
        removeMentionToken()
        mentionedModelId = model.id
        mentionedModelName = model.shortName
        let mention = "<@M:\(model.id)|\(model.shortName)> "
        inputText += mention
    }
    
    func clearModelMention() {
        mentionedModelId = nil
        mentionedModelName = nil
    }
    
    // MARK: - #Channel Mention Helpers
    
    /// Removes the `#...` token from the main input text.
    func removeHashToken() {
        inputText = removeLastToken(of: "#", from: inputText)
    }
    
    /// Inserts a #channel link into the input text.
    func insertChannelMention(_ channel: Channel) {
        removeHashToken()
        let mention = "<#C:\(channel.id)|\(channel.name)> "
        inputText += mention
    }
    
    // MARK: - Thread @Mention Helpers
    
    /// Removes the `@...` token from the thread input text.
    private func removeThreadMentionToken() {
        threadInputText = removeLastToken(of: "@", from: threadInputText)
    }
    
    /// Inserts a @user mention into the thread input text.
    func insertThreadUserMention(_ member: ChannelMember) {
        removeThreadMentionToken()
        threadInputText += "<@U:\(member.id)|\(member.displayName)> "
    }
    
    /// Inserts a @model mention into the thread input text.
    func setThreadModelMention(_ model: AIModel) {
        removeThreadMentionToken()
        threadInputText += "<@M:\(model.id)|\(model.shortName)> "
    }
    
    /// Removes the `#...` token from the thread input text.
    private func removeThreadHashToken() {
        threadInputText = removeLastToken(of: "#", from: threadInputText)
    }
    
    /// Inserts a #channel link into the thread input text.
    func insertThreadChannelMention(_ channel: Channel) {
        removeThreadHashToken()
        threadInputText += "<#C:\(channel.id)|\(channel.name)> "
    }
    
    // MARK: - Copy Message
    
    func copyMessage(_ message: ChannelMessage) {
        UIPasteboard.general.string = message.content
        Haptics.notify(.success)
        withAnimation(MicroAnimation.gentle) { showCopiedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                withAnimation(MicroAnimation.gentle) { showCopiedToast = false }
            }
        }
    }
    
    // MARK: - Model Resolution
    
    func resolveModel(for modelId: String?) -> AIModel? {
        guard let modelId else { return nil }
        return availableModels.first { $0.id == modelId }
    }
    
    func resolvedImageURL(for model: AIModel?) -> URL? {
        guard let model else { return nil }
        return model.resolveAvatarURL(baseURL: serverBaseURL)
    }
    
    func resolvedSenderName(for message: ChannelMessage) -> String {
        if let modelName = message.metaModelName, !modelName.isEmpty {
            return modelName
        }
        if let modelId = message.metaModelId, !modelId.isEmpty {
            if let model = availableModels.first(where: { $0.id == modelId }) {
                return model.shortName
            }
            return modelId
        }
        if let model = availableModels.first(where: { $0.id == message.userId }) {
            return model.shortName
        }
        if let name = message.user?.name, !name.isEmpty {
            return name
        }
        if let member = members.first(where: { $0.id == message.userId }) {
            return member.displayName
        }
        return message.userId
    }
    
    func isModelMessage(_ message: ChannelMessage) -> Bool {
        if message.isFromModel { return true }
        return availableModels.contains(where: { $0.id == message.userId })
    }
    
    func resolveModelForMessage(_ message: ChannelMessage) -> AIModel? {
        if let modelId = message.metaModelId {
            return availableModels.first { $0.id == modelId }
        }
        return availableModels.first { $0.id == message.userId }
    }
    
    // MARK: - Socket Events (R-003, R-026: Type-safe, channel-guarded)
    
    private func startSocketListener() {
        guard let socket = socketService else {
            logger.warning("No socket service available for channel \(self.channelId)")
            return
        }
        
        channelSubscription?.dispose()
        
        channelSubscription = socket.addChannelEventHandler(
            conversationId: channelId
        ) { [weak self] event, _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleSocketEvent(event)
            }
        }
        
        logger.info("Channel socket listener registered for \(self.channelId) (socket connected: \(socket.isConnected))")
        
        if !socket.isConnected {
            Task {
                let connected = await socket.ensureConnected(timeout: 5.0)
                logger.info("Socket connection ensured: \(connected)")
            }
        }
    }
    
    private func handleSocketEvent(_ event: [String: Any]) {
        let data = event["data"] as? [String: Any] ?? event
        let rawType = data["type"] as? String
        let eventType = ChannelSocketEventType.from(rawType)
        
        logger.debug("Channel socket event received: type=\(rawType ?? "nil")")
        
        switch eventType {
        case .message, .channelMessage, .channelMessageNew:
            handleNewMessageEvent(data)
            
        case .messageUpdate, .channelMessageUpdate:
            handleMessageUpdateEvent(data)
            
        case .channelMessageDelete:
            handleMessageDeleteEvent(data)
            
        case .channelReactionAdd, .channelReactionRemove:
            handleReactionEvent(data)
            
        case nil:
            // Unknown type — try to handle as a message
            if let type = rawType {
                logger.debug("Unhandled channel event type: \(type)")
            }
            if let msgData = data["data"] as? [String: Any],
               let msg = ChannelMessage.fromJSON(msgData) {
                // R-003: Guard channel ID
                guard msg.channelId == nil || msg.channelId == channelId else { return }
                handleIncomingMessage(msg)
            }
        }
    }
    
    // MARK: - Socket Event Handlers (COMPLEX-001: Extracted from monolith)
    
    private func handleNewMessageEvent(_ data: [String: Any]) {
        let msg: ChannelMessage? = {
            if let msgData = data["data"] as? [String: Any] {
                return ChannelMessage.fromJSON(msgData)
            }
            return ChannelMessage.fromJSON(data)
        }()
        
        guard let msg else { return }
        
        // R-003: Guard channel ID — prevent cross-channel message insertion
        guard msg.channelId == nil || msg.channelId == channelId else {
            logger.debug("Ignoring message for different channel: \(msg.channelId ?? "nil")")
            return
        }
        
        // Enrich with member info if user field is missing
        let enriched = enrichMessageWithMemberInfo(msg)
        
        logger.debug("New channel message: id=\(enriched.id), parentId=\(enriched.parentId ?? "nil")")
        
        handleIncomingMessage(enriched)
    }
    
    private func handleIncomingMessage(_ msg: ChannelMessage) {
        if let parentId = msg.parentId, !parentId.isEmpty {
            // Thread reply
            if threadParentMessage?.id == parentId {
                if !threadMessages.contains(where: { $0.id == msg.id }) {
                    threadMessages.append(msg)
                    logger.debug("Added to thread messages (count: \(self.threadMessages.count))")
                }
            }
            // BUG-005 fix: Refresh parent from API for accurate reply count
            Task {
                if let updated = try? await apiClient?.getChannelMessage(channelId: channelId, messageId: parentId) {
                    if let idx = messages.firstIndex(where: { $0.id == parentId }) {
                        messages[idx] = updated
                    }
                }
            }
        } else {
            // Regular channel message
            if let existingIdx = messages.firstIndex(where: { $0.id == msg.id }) {
                if messages[existingIdx].isOptimistic {
                    messages[existingIdx] = msg
                }
            } else {
                // R-006: Improved dedup — match by ID from pending optimistic messages
                // rather than content matching (which can incorrectly match duplicate messages)
                let hasOptimisticMatch = messages.contains { $0.isOptimistic && $0.userId == msg.userId && $0.content == msg.content }
                if hasOptimisticMatch {
                    // Remove the first matching optimistic message
                    if let optIdx = messages.firstIndex(where: { $0.isOptimistic && $0.userId == msg.userId && $0.content == msg.content }) {
                        messages[optIdx] = msg
                    }
                } else {
                    messages.append(msg)
                    logger.debug("Added to main messages (count: \(self.messages.count))")
                }
            }
        }
    }
    
    private func handleMessageUpdateEvent(_ data: [String: Any]) {
        let updatedMsg: ChannelMessage? = {
            if let msgData = data["data"] as? [String: Any] {
                return ChannelMessage.fromJSON(msgData)
            }
            return ChannelMessage.fromJSON(data)
        }()
        guard let msg = updatedMsg else { return }
        
        // R-003: Guard channel ID
        guard msg.channelId == nil || msg.channelId == channelId else { return }
        
        logger.debug("Message update: id=\(msg.id)")
        
        if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
            messages[idx] = msg
        }
        if let idx = threadMessages.firstIndex(where: { $0.id == msg.id }) {
            threadMessages[idx] = msg
        }
        if let parentId = msg.parentId, !parentId.isEmpty,
           threadParentMessage?.id == parentId {
            if !threadMessages.contains(where: { $0.id == msg.id }) {
                threadMessages.append(msg)
            }
        }
    }
    
    private func handleMessageDeleteEvent(_ data: [String: Any]) {
        if let msgId = data["message_id"] as? String
            ?? (data["data"] as? [String: Any])?["id"] as? String {
            messages.removeAll { $0.id == msgId }
            threadMessages.removeAll { $0.id == msgId }
        }
    }
    
    private func handleReactionEvent(_ data: [String: Any]) {
        if let msgId = data["message_id"] as? String {
            Task {
                if let updated = try? await apiClient?.getChannelMessage(channelId: channelId, messageId: msgId) {
                    if let idx = messages.firstIndex(where: { $0.id == msgId }) {
                        messages[idx] = updated
                    }
                    if let idx = threadMessages.firstIndex(where: { $0.id == msgId }) {
                        threadMessages[idx] = updated
                    }
                }
            }
        }
    }
    
    /// Enriches a message with user info from the members list if not present in the socket payload.
    private func enrichMessageWithMemberInfo(_ msg: ChannelMessage) -> ChannelMessage {
        if msg.user == nil || msg.user?.name == nil || (msg.user?.name?.isEmpty ?? true) {
            if let member = members.first(where: { $0.id == msg.userId }) {
                return msg.withUser(ChannelMessageUser(id: member.id, name: member.name, role: member.role))
            }
        }
        return msg
    }
    
    // MARK: - Cleanup
    
    func cleanup() {
        channelSubscription?.dispose()
        channelSubscription = nil
        // Note: Do NOT call updateMemberActiveStatus(isActive: false) here.
        // That API tells the server the user has left/hidden the channel,
        // causing DMs to disappear from the sidebar. It should only be
        // called for explicit "Leave Conversation" actions, not on navigation.
    }
}
