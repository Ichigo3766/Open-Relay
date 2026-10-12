import Foundation
import os.log
import SwiftUI

// MARK: - Animation constants (channel message list)
private extension Animation {
    /// Quick ease-out used for message removal / insertion animations.
    static let messageRemove = Animation.easeOut(duration: 0.18)
    /// Gentle spring used for content updates (edits, reactions, pins).
    static let messageUpdate = Animation.easeInOut(duration: 0.15)
}

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
    /// Message awaiting delete confirmation (web: ConfirmDialog "Delete Message").
    var pendingDeleteMessage: ChannelMessage?

    // Thread state — uses separate attachment array (BUG-011 fix)
    var threadParentMessage: ChannelMessage?
    var threadMessages: [ChannelMessage] = []
    var isLoadingThread: Bool = false
    /// Thread pagination (web Thread.svelte loads older replies in pages of 50).
    var isLoadingOlderThread = false
    var allThreadLoaded = false
var threadInputText: String = ""
    /// Message being replied to *inside* the open thread (web Thread.svelte `replyToMessage`).
    var threadReplyToMessage: ChannelMessage?
var threadAttachments: [ChatAttachment] = []
    
    // @mention state
    var mentionedModelId: String?
    var mentionedModelName: String?
    
    // Typing indicators — users currently typing in this channel
    var typingUsers: [TypingUser] = []
    /// Users typing inside the currently open thread.
    var threadTypingUsers: [TypingUser] = []

    // Members sheet (server-paginated, searchable)
    var memberSearchResults: [ChannelMember] = []
    var memberTotal: Int = 0
    var isLoadingMemberPage = false
    private var memberPage = 1
    private var memberQuery = ""
    private var memberSearchTask: Task<Void, Never>?
    var hasMoreMembers: Bool { memberSearchResults.count < memberTotal }

    // Pinned messages (paginated)
    var isLoadingPinned = false
    private var pinnedPage = 1
    var allPinnedLoaded = false

    // Webhooks (managers only)
    var webhooks: [ChannelWebhook] = []
    var isLoadingWebhooks = false

    // `/` prompt shortcuts (web parity: CommandSuggestionList in channel MessageInput)
    var availablePrompts: [PromptItem] = []
    var isLoadingPrompts = false
    var pendingPromptForVariables: PromptItem?
    var pendingPromptVariables: [PromptVariable] = []
    /// Which composer the pending prompt should be inserted into.
    var pendingPromptIsThread = false

    /// Set to scroll the timeline to (and highlight) a specific message, e.g. from pins.
    var jumpToMessageId: String?

    /// Whether the first page of history reached the start of the channel.
    var reachedChannelStart: Bool { allMessagesLoaded }

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

    /// Whether the signed-in user is a server admin.
    var isCurrentUserAdmin: Bool = false

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
    /// Web parity: admins or the channel owner (ChannelItem.svelte); group managers
    /// via the server's `is_manager` flag; any DM participant for DM settings.
    var canManageChannel: Bool {
        guard let channel, let userId = currentUserId else { return false }
        if isDM {
            return members.contains(where: { $0.id == userId }) || channel.userIds.contains(userId)
        }
        return isCurrentUserAdmin || channel.userId == userId || channel.isManager
    }

    /// Whether the user can add/remove members of a group channel (web: `is_manager`).
    var canManageMembers: Bool {
        guard let channel else { return false }
        return channel.type == .group && (channel.isManager || isCurrentUserAdmin)
    }

    /// Web parity: authors and admins may edit/delete a message (server enforces the same).
    func canModify(_ message: ChannelMessage) -> Bool {
        guard !message.isOptimistic else { return false }
        if isCurrentUserAdmin { return true }
        return message.userId == currentUserId && !isModelMessage(message)
    }

    /// Members count for the header — prefers the server's `user_count`.
    var memberCount: Int {
        channel?.userCount ?? members.count
    }

    /// When replying to a model's message the backend auto-mentions that model.
    /// Returns its display name so the composer can say "<Model> will respond".
    var replyTargetModelName: String? {
        guard let reply = replyToMessage, isModelMessage(reply) else { return nil }
        return resolvedSenderName(for: reply)
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

    /// One pending expiry per typing user (key: "c:<uid>" channel, "t:<uid>" thread).
    private var typingExpiryTasks: [String: Task<Void, Never>] = [:]
    /// Last typing emit per scope ("" = channel, otherwise thread parent id).
    private var lastTypingEmit: [String: Date] = [:]

    // MARK: - Init
    
    init(channelId: String) {
        self.channelId = channelId
    }
    
    // MARK: - Configuration
    
    func configure(apiClient: APIClient, socket: SocketIOService?, currentUserId: String?, isAdmin: Bool = false) {
        self.apiClient = apiClient
        self.socketService = socket
        self.currentUserId = currentUserId
        self.isCurrentUserAdmin = isAdmin
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
        
        // Emit last_read_at so the server resets unread_count for this channel
        markAsRead()
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
            members = try await apiClient.getAllChannelMembers(id: channelId)
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
    
    /// Loads the first page of pinned messages (resets pagination).
    func loadPinnedMessages() async {
        guard let apiClient else { return }
        isLoadingPinned = true
        pinnedPage = 1
        allPinnedLoaded = false
        do {
            let page = try await apiClient.getPinnedChannelMessages(channelId: channelId, page: 1)
            pinnedMessages = page
            allPinnedLoaded = page.isEmpty
        } catch {
            logger.error("Failed to load pinned messages: \(error.localizedDescription)")
        }
        isLoadingPinned = false
    }

    /// Loads the next page of pinned messages (web: infinite scroll in PinnedMessagesModal).
    func loadMorePinnedMessages() async {
        guard let apiClient, !allPinnedLoaded, !isLoadingPinned else { return }
        isLoadingPinned = true
        let next = pinnedPage + 1
        do {
            let page = try await apiClient.getPinnedChannelMessages(channelId: channelId, page: next)
            let existing = Set(pinnedMessages.map(\.id))
            let fresh = page.filter { !existing.contains($0.id) }
            pinnedMessages.append(contentsOf: fresh)
            pinnedPage = next
            if fresh.isEmpty { allPinnedLoaded = true }
        } catch {
            logger.error("Failed to load more pinned messages: \(error.localizedDescription)")
        }
        isLoadingPinned = false
    }

    /// Unpins a message from the pinned list (message may not be in the loaded timeline).
    func unpinFromList(_ message: ChannelMessage) async {
        guard let apiClient else { return }
        pinnedMessages.removeAll { $0.id == message.id }
        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages[idx].isPinned = false
        }
        do {
            _ = try await apiClient.pinChannelMessage(channelId: channelId, messageId: message.id, isPinned: false)
        } catch {
            logger.error("Failed to unpin: \(error.localizedDescription)")
            await loadPinnedMessages()
        }
    }

    // MARK: - Members (paginated / searchable)

    /// Resets and loads page 1 of members for the members sheet, optionally filtered.
    func searchMembers(_ query: String, debounce: Bool = true) {
        memberSearchTask?.cancel()
        memberSearchTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled, let self else { return }
            await self.loadMemberPage(query: query, page: 1)
        }
    }

    func loadMoreMembers() async {
        guard hasMoreMembers, !isLoadingMemberPage else { return }
        await loadMemberPage(query: memberQuery, page: memberPage + 1)
    }

    private func loadMemberPage(query: String, page: Int) async {
        guard let apiClient else { return }
        isLoadingMemberPage = true
        do {
            let result = try await apiClient.getChannelMembersPage(id: channelId, query: query, page: page)
            guard !Task.isCancelled else { isLoadingMemberPage = false; return }
            if page == 1 {
                memberSearchResults = result.members
            } else {
                let existing = Set(memberSearchResults.map(\.id))
                memberSearchResults.append(contentsOf: result.members.filter { !existing.contains($0.id) })
            }
            memberTotal = result.total
            memberPage = page
            memberQuery = query
        } catch {
            logger.error("Failed to load member page: \(error.localizedDescription)")
        }
        isLoadingMemberPage = false
    }

    /// Adds users/groups to a group channel then refreshes channel + members.
    func addMembers(userIds: [String], groupIds: [String]) async throws {
        guard let apiClient else { return }
        try await apiClient.addChannelMembers(id: channelId, userIds: userIds, groupIds: groupIds)
        await loadChannel()
        await loadMembers()
        await loadMemberPage(query: memberQuery, page: 1)
    }

    /// Removes a member from a group channel (managers only).
    func removeMember(userId: String) async throws {
        guard let apiClient, userId != currentUserId else { return }
        try await apiClient.removeChannelMembers(id: channelId, userIds: [userId])
        memberSearchResults.removeAll { $0.id == userId }
        memberTotal = max(0, memberTotal - 1)
        members.removeAll { $0.id == userId }
        await loadChannel()
    }

    /// Fetches the full profile (status, bio, groups) for the profile card.
    func loadUserProfile(userId: String) async -> ChannelMember? {
        guard let apiClient else { return nil }
        return try? await apiClient.getUserInfo(userId: userId)
    }

    /// Opens (or creates) the DM with a user — returns the DM channel id.
    func directMessageChannelId(with userId: String) async -> String? {
        guard let apiClient else { return nil }
        return (try? await apiClient.getDMChannel(userId: userId))?.id
    }

    // MARK: - Webhooks

    func loadWebhooks() async {
        guard let apiClient else { return }
        isLoadingWebhooks = true
        do {
            webhooks = try await apiClient.listChannelWebhooks(channelId: channelId)
        } catch {
            logger.error("Failed to load webhooks: \(error.localizedDescription)")
            webhooks = []
        }
        isLoadingWebhooks = false
    }

    func createWebhook(name: String = "New Webhook") async throws -> ChannelWebhook? {
        guard let apiClient else { return nil }
        let created = try await apiClient.createChannelWebhook(channelId: channelId, name: name)
        if let created { webhooks.append(created) }
        return created
    }

    func updateWebhook(_ webhook: ChannelWebhook, name: String, profileImageURL: String?) async throws {
        guard let apiClient else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = try await apiClient.updateChannelWebhook(
            channelId: channelId, webhookId: webhook.id,
            name: trimmed.isEmpty ? webhook.name : trimmed,
            profileImageURL: profileImageURL
        )
        if let updated, let idx = webhooks.firstIndex(where: { $0.id == webhook.id }) {
            webhooks[idx] = updated
        }
    }

    func deleteWebhook(_ webhook: ChannelWebhook) async throws {
        guard let apiClient else { return }
        try await apiClient.deleteChannelWebhook(channelId: channelId, webhookId: webhook.id)
        webhooks.removeAll { $0.id == webhook.id }
    }

    func webhookURL(_ webhook: ChannelWebhook) -> String {
        apiClient?.channelWebhookURL(webhook) ?? ""
    }
    
    func loadAllServerUsers() async {
        guard let apiClient else { return }
        do {
            allServerUsers = try await apiClient.searchAllUsers()
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
    
    /// Server results for the current `@` query (web MentionList: members + /users/search).
    var mentionSearchResults: [ChannelMember] = []
    private var mentionSearchTask: Task<Void, Never>?

    /// Debounced server search while typing after `@` — finds users beyond any loaded page.
    func searchMentions(_ query: String) {
        mentionSearchTask?.cancel()
        guard let apiClient else { return }
        let channelId = self.channelId
        mentionSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            async let membersPage = try? apiClient.getChannelMembersPage(id: channelId, query: query, page: 1)
            async let globalPage = try? apiClient.searchUsers(query: query.isEmpty ? nil : query, page: 1)
            let (m, g) = await (membersPage, globalPage)
            guard !Task.isCancelled, let self else { return }
            let memberResults = m?.members ?? []
            let memberIds = Set(memberResults.map(\.id))
            self.mentionSearchResults = memberResults + (g ?? []).filter { !memberIds.contains($0.id) }
        }
    }

    /// Candidates for the `@` picker: server results for the query merged with everything
    /// already loaded (members first, then other users), deduped.
    func mentionCandidates(for query: String) -> [ChannelMember] {
        let q = query.lowercased()
        let local = mentionCandidates.filter {
            q.isEmpty || $0.displayName.lowercased().contains(q) || $0.email.lowercased().contains(q)
        }
        var seen = Set<String>()
        let memberIds = Set(members.map(\.id))
        let merged = (mentionSearchResults + local).filter { seen.insert($0.id).inserted }
        // Members first, then everyone else; alphabetical within each group.
        let byName: (ChannelMember, ChannelMember) -> Bool = {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return merged.filter { memberIds.contains($0.id) }.sorted(by: byName)
            + merged.filter { !memberIds.contains($0.id) }.sorted(by: byName)
    }

    /// @mention candidates: channel members first, then other server users (web MentionList parity).
    var mentionCandidates: [ChannelMember] {
        let byName: (ChannelMember, ChannelMember) -> Bool = {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let memberIds = Set(members.map(\.id))
        let others = allServerUsers.filter { !memberIds.contains($0.id) }
        return members.sorted(by: byName) + others.sorted(by: byName)
    }

    var availableChannelsForPicker: [Channel] {
        availableChannels.filter { $0.id != channelId }
    }
    
    var accessibleChannelIds: Set<String> {
        Set(availableChannels.map(\.id))
    }
    
    // MARK: - Send Message

    /// Messages sent while an earlier one is still sending (or a file is
    /// still uploading) wait here and go out in order. Each can be sent now, edited
    /// or removed from the queue view above the input.
    var messageQueue: [QueuedMessage] = []
    private var isSendingMessage = false
    /// Attachments + reply/model context captured with each queued text.
    private var queuedContext: [UUID: (attachments: [ChatAttachment], replyTo: ChannelMessage?, modelId: String?, modelName: String?)] = [:]

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        if isSendingMessage || !messageQueue.isEmpty {
            let item = QueuedMessage(id: UUID(), text: text)
            queuedContext[item.id] = (attachments, replyToMessage, mentionedModelId, mentionedModelName)
            messageQueue.append(item)
            inputText = ""
            attachments = []
            replyToMessage = nil
            mentionedModelId = nil
            mentionedModelName = nil
            Task { await drainQueueWhenReady() }
            return
        }
        await performSend()
        await drainQueueWhenReady()
    }

    /// Sends one queued message immediately (skipping its place in line).
    func sendQueuedNow(_ id: UUID) async {
        guard let item = messageQueue.first(where: { $0.id == id }) else { return }
        messageQueue.removeAll { $0.id == id }
        await sendQueued(item)
    }

    /// Puts a queued message back in the input for editing.
    func editQueued(_ id: UUID) {
        guard let item = messageQueue.first(where: { $0.id == id }) else { return }
        messageQueue.removeAll { $0.id == id }
        let context = queuedContext.removeValue(forKey: id)
        inputText = item.text
        attachments = context?.attachments ?? []
        replyToMessage = context?.replyTo
        mentionedModelId = context?.modelId
        mentionedModelName = context?.modelName
    }

    func removeQueued(_ id: UUID) {
        messageQueue.removeAll { $0.id == id }
        queuedContext.removeValue(forKey: id)
    }

    private func sendQueued(_ item: QueuedMessage) async {
        let context = queuedContext.removeValue(forKey: item.id)
        // Swap the queued context into the composer state, send, then restore drafts.
        let draft = (inputText, attachments, replyToMessage, mentionedModelId, mentionedModelName)
        inputText = item.text
        attachments = context?.attachments ?? []
        replyToMessage = context?.replyTo
        mentionedModelId = context?.modelId
        mentionedModelName = context?.modelName
        await performSend()
        inputText = draft.0
        attachments = draft.1
        replyToMessage = draft.2
        mentionedModelId = draft.3
        mentionedModelName = draft.4
    }

    /// Sends queued messages in order once nothing is sending. Queued attachments
    /// that hadn't finished uploading are uploaded by `performSend` itself.
    private func drainQueueWhenReady() async {
        while !messageQueue.isEmpty {
            if isSendingMessage { return }
            let next = messageQueue.removeFirst()
            await sendQueued(next)
        }
    }

    private func performSend() async {
        isSendingMessage = true
        defer { isSendingMessage = false }
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
                let fileObject = attachment.uploadedFileObject ?? [:]
                let isImage = attachment.type == .image
                let contentType: String = isImage ? "image/jpeg" : "application/octet-stream"
                let size: Int = (fileObject["meta"] as? [String: Any]).flatMap { $0["size"] as? Int } ?? 0
                fileRefs.append([
                    "type": "file",
                    "file": fileObject.isEmpty ? ["id": fileId, "filename": attachment.name, "meta": ["name": attachment.name, "content_type": contentType, "size": size]] : fileObject,
                    "id": fileId,
                    "url": fileId,
                    "name": attachment.name,
                    "status": "uploaded",
                    "size": size,
                    "error": "",
                    "content_type": contentType
                ])
            } else if let data = attachment.data {
                do {
                    let (fileId, fileObject) = try await apiClient.uploadFile(data: data, fileName: attachment.name)
                    let isImage = attachment.type == .image
                    let contentType: String = isImage ? "image/jpeg" : "application/octet-stream"
                    let size: Int = (fileObject["meta"] as? [String: Any]).flatMap { $0["size"] as? Int } ?? 0
                    fileRefs.append([
                        "type": "file",
                        "file": fileObject.isEmpty ? ["id": fileId, "filename": attachment.name, "meta": ["name": attachment.name, "content_type": contentType, "size": size]] : fileObject,
                        "id": fileId,
                        "url": fileId,
                        "name": attachment.name,
                        "status": "uploaded",
                        "size": size,
                        "error": "",
                        "content_type": contentType
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
        
        // Send to server — include temp_id so the socket broadcast can carry it back,
        // allowing us to match the confirmed message to the optimistic placeholder by ID.
        do {
            let serverMsg = try await apiClient.postChannelMessage(
                channelId: channelId,
                content: currentText,
                replyToId: replyId,
                data: msgData.isEmpty ? nil : msgData,
                tempId: tempId
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
        let threadReplyId = threadReplyToMessage?.id
        threadReplyToMessage = nil
        let currentAttachments = threadAttachments
        threadAttachments = []
        
        var msgData: [String: Any] = [:]
        var fileRefs: [[String: Any]] = []
        for attachment in currentAttachments {
            if let fileId = attachment.uploadedFileId {
                let fileObject = attachment.uploadedFileObject ?? [:]
                let isImage = attachment.type == .image
                let contentType: String = isImage ? "image/jpeg" : "application/octet-stream"
                let size: Int = (fileObject["meta"] as? [String: Any]).flatMap { $0["size"] as? Int } ?? 0
                fileRefs.append([
                    "type": "file",
                    "file": fileObject.isEmpty ? ["id": fileId, "filename": attachment.name, "meta": ["name": attachment.name, "content_type": contentType, "size": size]] : fileObject,
                    "id": fileId,
                    "url": fileId,
                    "name": attachment.name,
                    "status": "uploaded",
                    "size": size,
                    "error": "",
                    "content_type": contentType
                ])
            } else if let data = attachment.data {
                do {
                    let (fileId, fileObject) = try await apiClient.uploadFile(data: data, fileName: attachment.name)
                    let isImage = attachment.type == .image
                    let contentType: String = isImage ? "image/jpeg" : "application/octet-stream"
                    let size: Int = (fileObject["meta"] as? [String: Any]).flatMap { $0["size"] as? Int } ?? 0
                    fileRefs.append([
                        "type": "file",
                        "file": fileObject.isEmpty ? ["id": fileId, "filename": attachment.name, "meta": ["name": attachment.name, "content_type": contentType, "size": size]] : fileObject,
                        "id": fileId,
                        "url": fileId,
                        "name": attachment.name,
                        "status": "uploaded",
                        "size": size,
                        "error": "",
                        "content_type": contentType
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
                replyToId: threadReplyId,
                parentId: parentId,
                data: msgData.isEmpty ? nil : msgData
            )
            if let msg {
                // Dedup: socket may have already delivered this message while the API
                // call was in flight — update in place rather than appending a duplicate.
                if let idx = threadMessages.firstIndex(where: { $0.id == msg.id }) {
                    threadMessages[idx] = msg
                } else {
                    threadMessages.append(msg)
                }
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
        
        // Optimistic removal — animated so the list collapses immediately
        let removedIdx = messages.firstIndex(where: { $0.id == id })
        let removedMsg = removedIdx.map { messages[$0] }
        if let idx = removedIdx {
            withAnimation(.messageRemove) { _ = messages.remove(at: idx) }
        }
        
        let removedThreadIdx = threadMessages.firstIndex(where: { $0.id == id })
        let removedThreadMsg = removedThreadIdx.map { threadMessages[$0] }
        if let idx = removedThreadIdx {
            withAnimation(.messageRemove) { _ = threadMessages.remove(at: idx) }
        }
        
        do {
            try await apiClient.deleteChannelMessage(channelId: channelId, messageId: id)
            applyDeletionSideEffects(for: id)
        } catch {
            // Revert on failure
            if let msg = removedMsg, let idx = removedIdx {
                withAnimation(.messageRemove) {
                    messages.insert(msg, at: min(idx, messages.count))
                }
            }
            if let msg = removedThreadMsg, let idx = removedThreadIdx {
                withAnimation(.messageRemove) {
                    threadMessages.insert(msg, at: min(idx, threadMessages.count))
                }
            }
            logger.error("Failed to delete message: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Reactions (R-028: Rate limited)
    
    func toggleReaction(messageId: String, emoji rawEmoji: String) async {
        guard let apiClient, let userId = currentUserId else { return }
        // Web stores reactions as shortcodes ("+1", "heart"). Match an existing chip first
        // (it may be a legacy raw-emoji reaction) so toggling removes the right one.
        let shortcode = rawEmoji.emojiShortcode
        let emoji: String = {
            let reactions = (messages.first(where: { $0.id == messageId })
                ?? threadMessages.first(where: { $0.id == messageId }))?.reactions ?? []
            if reactions.contains(where: { $0.name == shortcode }) { return shortcode }
            if reactions.contains(where: { $0.name == rawEmoji }) { return rawEmoji }
            if let match = reactions.first(where: { $0.name.emojiFromShortcode == rawEmoji.emojiFromShortcode }) {
                return match.name
            }
            return shortcode
        }()
        if messages.firstIndex(where: { $0.id == messageId }) == nil {
            await toggleThreadReaction(messageId: messageId, emoji: emoji, userId: userId, apiClient: apiClient)
            return
        }
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

    /// Reactions on thread replies (not present in the main timeline).
    private func toggleThreadReaction(messageId: String, emoji: String, userId: String, apiClient: APIClient) async {
        guard let idx = threadMessages.firstIndex(where: { $0.id == messageId }) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastReactionTime) >= reactionCooldown else { return }
        lastReactionTime = now

        let hasReacted = threadMessages[idx].hasReaction(emoji, byUserId: userId)
        if hasReacted {
            if let rIdx = threadMessages[idx].reactions.firstIndex(where: { $0.name == emoji }) {
                threadMessages[idx].reactions[rIdx].userIds.removeAll { $0 == userId }
                threadMessages[idx].reactions[rIdx].count = max(0, threadMessages[idx].reactions[rIdx].count - 1)
                if threadMessages[idx].reactions[rIdx].count == 0 { threadMessages[idx].reactions.remove(at: rIdx) }
            }
        } else if let rIdx = threadMessages[idx].reactions.firstIndex(where: { $0.name == emoji }) {
            threadMessages[idx].reactions[rIdx].userIds.append(userId)
            threadMessages[idx].reactions[rIdx].count += 1
        } else {
            threadMessages[idx].reactions.append(MessageReaction(name: emoji, userIds: [userId], userNames: [], count: 1))
        }
        do {
            if hasReacted {
                try await apiClient.removeChannelReaction(channelId: channelId, messageId: messageId, emoji: emoji)
            } else {
                try await apiClient.addChannelReaction(channelId: channelId, messageId: messageId, emoji: emoji)
            }
        } catch {
            logger.error("Failed to toggle thread reaction: \(error.localizedDescription)")
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
            if newPinned {
                if !pinnedMessages.contains(where: { $0.id == messageId }),
                   let msg = messages.first(where: { $0.id == messageId }) {
                    pinnedMessages.insert(msg, at: 0)
                }
            } else {
                pinnedMessages.removeAll { $0.id == messageId }
            }
        } catch {
            if let i = messages.firstIndex(where: { $0.id == messageId }) {
                messages[i].isPinned = !newPinned
            }
            logger.error("Failed to toggle pin: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Threading
    
    private var threadLoadGeneration = 0

    func openThread(for message: ChannelMessage) async {
        threadLoadGeneration &+= 1
        let generation = threadLoadGeneration
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
            guard generation == threadLoadGeneration else { return }
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
                allThreadLoaded = fetched.count < pageSize
                await loadThreadMessageDataForAll()
            }
        } catch {
            logger.error("Failed to load thread: \(error.localizedDescription)")
        }
        
        if generation == threadLoadGeneration { isLoadingThread = false }
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
    
    /// Loads older replies of the open thread (prepends).
    func loadOlderThreadMessages() async {
        guard let apiClient, let parent = threadParentMessage,
              !allThreadLoaded, !isLoadingOlderThread, !isLoadingThread else { return }
        isLoadingOlderThread = true
        let generation = threadLoadGeneration
        do {
            let fetched = try await apiClient.getChannelThreadMessages(
                channelId: channelId, messageId: parent.id, skip: threadMessages.count, limit: pageSize
            )
            guard generation == threadLoadGeneration else { isLoadingOlderThread = false; return }
            let existing = Set(threadMessages.map(\.id))
            let older = fetched.reversed().filter { !existing.contains($0.id) }
            threadMessages.insert(contentsOf: older, at: 0)
            if fetched.count < pageSize { allThreadLoaded = true }
            for msg in older where msg.hasData { await loadThreadMessageData(for: msg.id) }
        } catch {
            logger.error("Failed to load older thread messages: \(error.localizedDescription)")
        }
        isLoadingOlderThread = false
    }

    func closeThread() {
        allThreadLoaded = false
        threadTypingUsers = []
        threadReplyToMessage = nil
        threadLoadGeneration &+= 1
        isLoadingThread = false
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

    /// Reply to a specific message inside the open thread.
    func setThreadReplyTo(_ message: ChannelMessage) {
        threadReplyToMessage = message
    }

    func clearThreadReply() {
        threadReplyToMessage = nil
    }

    /// Replying to a model's thread message makes that model answer (server behaviour).
    var threadReplyTargetModelName: String? {
        guard let reply = threadReplyToMessage, isModelMessage(reply) else { return nil }
        return resolvedSenderName(for: reply)
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
                let (fileId, fileObject) = try await apiClient.uploadFile(data: data, fileName: fileName)
                if isThread {
                    if let i = threadAttachments.firstIndex(where: { $0.id == attachmentId }) {
                        threadAttachments[i].uploadStatus = .completed
                        threadAttachments[i].uploadedFileId = fileId
                        threadAttachments[i].uploadedFileObject = fileObject
                        threadAttachments[i].data = nil
                    }
                } else {
                    if let i = attachments.firstIndex(where: { $0.id == attachmentId }) {
                        attachments[i].uploadStatus = .completed
                        attachments[i].uploadedFileId = fileId
                        attachments[i].uploadedFileObject = fileObject
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
    
    // MARK: - `/` Prompts

    /// Loads active prompts (stale-while-revalidate, like the main chat).
    func loadPrompts() {
        guard let apiClient else { return }
        if availablePrompts.isEmpty { isLoadingPrompts = true }
        Task {
            if let raw = try? await apiClient.getPrompts() {
                availablePrompts = raw.compactMap { PromptItem(json: $0) }.filter(\.isActive)
            }
            isLoadingPrompts = false
        }
    }

    /// Inserts a selected prompt (or asks for its variables first).
    func selectPrompt(_ prompt: PromptItem, isThread: Bool) {
        if isThread {
            threadInputText = removeLastToken(of: "/", from: threadInputText)
        } else {
            inputText = removeLastToken(of: "/", from: inputText)
        }
        let variables = PromptService.extractCustomVariables(from: prompt.content)
        if variables.isEmpty {
            let processed = PromptService.resolveSystemVariables(in: prompt.content, userName: nil, userEmail: nil)
            appendPromptText(processed, isThread: isThread)
        } else {
            pendingPromptIsThread = isThread
            pendingPromptVariables = variables
            pendingPromptForVariables = prompt
        }
        Haptics.play(.light)
    }

    func submitPromptVariables(values: [String: String]) {
        guard let prompt = pendingPromptForVariables else { return }
        let processed = PromptService.processPrompt(
            content: prompt.content, userValues: values,
            variables: pendingPromptVariables, userName: nil, userEmail: nil
        )
        appendPromptText(processed, isThread: pendingPromptIsThread)
        cancelPromptVariables()
    }

    func cancelPromptVariables() {
        pendingPromptForVariables = nil
        pendingPromptVariables = []
    }

    private func appendPromptText(_ text: String, isThread: Bool) {
        if isThread {
            let remaining = threadInputText.trimmingCharacters(in: .whitespaces)
            threadInputText = remaining.isEmpty ? text : remaining + " " + text
        } else {
            let remaining = inputText.trimmingCharacters(in: .whitespaces)
            inputText = remaining.isEmpty ? text : remaining + " " + text
        }
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
            
        case .messageDelete, .channelMessageDelete:
            handleMessageDeleteEvent(data)

        case .messageReply:
            handleMessageReplyEvent(data)

        case .channelMessagePinned, .channelMessageUnpinned,
             .messagePinned, .messageUnpinned:
            handlePinEvent(data)

        case .channelReactionAdd, .channelReactionRemove,
             .messageReactionAdd, .messageReactionRemove:
            handleReactionEvent(data)
            
        case .typing:
            handleTypingEvent(event)
            
        case .channelCreated, .channelUpdated, .channelDeleted:
            // Channel lifecycle events — handled by ChannelListViewModel
            break
            
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
        clearTyping(for: msg.userId, inThread: !(msg.parentId ?? "").isEmpty)
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
        // The server sends delete events with the id in several possible locations:
        //   { "message_id": "xxx" }
        //   { "id": "xxx" }
        //   { "data": { "id": "xxx" } }
        //   { "data": { "message_id": "xxx" } }
        let inner = data["data"] as? [String: Any]
        guard let msgId = data["message_id"] as? String
            ?? data["id"] as? String
            ?? inner?["id"] as? String
            ?? inner?["message_id"] as? String
        else { return }

        logger.debug("Remote message delete: id=\(msgId)")
        withAnimation(.messageRemove) {
            messages.removeAll { $0.id == msgId }
            threadMessages.removeAll { $0.id == msgId }
        }
        applyDeletionSideEffects(for: msgId)
    }

    /// Web parity after a message is deleted: drop quotes pointing to it, clear a pending
    /// reply to it, close its thread if open, and remove it from pinned messages.
    private func applyDeletionSideEffects(for msgId: String) {
        for i in messages.indices where messages[i].replyToId == msgId {
            messages[i].replyToId = nil
            messages[i].replyToMessage = nil
        }
        for i in threadMessages.indices where threadMessages[i].replyToId == msgId {
            threadMessages[i].replyToId = nil
            threadMessages[i].replyToMessage = nil
        }
        if replyToMessage?.id == msgId { replyToMessage = nil }
        if threadReplyToMessage?.id == msgId { threadReplyToMessage = nil }
        if editingMessage?.id == msgId { cancelEditing() }
        pinnedMessages.removeAll { $0.id == msgId }
        if threadParentMessage?.id == msgId { closeThread() }
    }

    /// Handles remote pin/unpin events from other clients.
    /// Tries to parse the full message from the payload; falls back to a single-field flip.
    private func handlePinEvent(_ data: [String: Any]) {
        // Try to get a full message object first — ideal path
        let msgData = data["data"] as? [String: Any] ?? data
        if let msg = ChannelMessage.fromJSON(msgData) {
            logger.debug("Remote pin event for id=\(msg.id), isPinned=\(msg.isPinned)")
            withAnimation(.messageUpdate) {
                if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                    messages[idx] = msg
                }
                if let idx = threadMessages.firstIndex(where: { $0.id == msg.id }) {
                    threadMessages[idx] = msg
                }
            }
            Task { await loadPinnedMessages() }
            return
        }

        // Fallback: just flip isPinned using message_id + event type
        let inner = data["data"] as? [String: Any]
        guard let msgId = data["message_id"] as? String
            ?? data["id"] as? String
            ?? inner?["id"] as? String
            ?? inner?["message_id"] as? String
        else { return }

        let rawType = (data["type"] as? String) ?? ""
        let nowPinned = rawType.contains("pinned") && !rawType.contains("unpinned")
        logger.debug("Remote pin flip for id=\(msgId), isPinned=\(nowPinned)")

        withAnimation(.messageUpdate) {
            if let idx = messages.firstIndex(where: { $0.id == msgId }) {
                messages[idx].isPinned = nowPinned
            }
            if let idx = threadMessages.firstIndex(where: { $0.id == msgId }) {
                threadMessages[idx].isPinned = nowPinned
            }
        }
        Task { await loadPinnedMessages() }
    }
    
    private func handleReactionEvent(_ data: [String: Any]) {
        // DEBUG: Log full payload so we can see exactly what the server sends
        logger.info("🔔 handleReactionEvent — top-level keys: \(data.keys.sorted().joined(separator: ", "))")
        for (k, v) in data {
            logger.info("  [\(k)]: \(String(describing: v))")
        }
        if let inner = data["data"] as? [String: Any] {
            logger.info("  data[\"data\"] keys: \(inner.keys.sorted().joined(separator: ", "))")
            for (k, v) in inner {
                logger.info("    inner[\(k)]: \(String(describing: v))")
            }
        } else {
            logger.info("  data[\"data\"] is nil or not a dict (raw: \(String(describing: data["data"])))")
        }

        // Try to parse an embedded full message first (avoids a round-trip to the server)
        let msgData = data["data"] as? [String: Any] ?? data
        if let msg = ChannelMessage.fromJSON(msgData) {
            logger.info("✅ handleReactionEvent — parsed full message id=\(msg.id), reactions=\(msg.reactions.map(\.name))")
            let enriched = enrichMessageWithMemberInfo(msg)
            if let idx = messages.firstIndex(where: { $0.id == enriched.id }) {
                messages[idx] = enriched
            }
            if let idx = threadMessages.firstIndex(where: { $0.id == enriched.id }) {
                threadMessages[idx] = enriched
            }
            return
        }
        logger.info("⚠️ handleReactionEvent — could not parse full message, trying API fallback")

        // Fallback: fetch from API when the socket payload only carries a message_id.
        // The reaction event nests message_id inside data["data"]:
        // { "type": "channel:reaction:add", "data": { "message_id": "yyy" } }
        let innerData = data["data"] as? [String: Any]
        let msgId = data["message_id"] as? String ?? innerData?["message_id"] as? String
        logger.info("🔍 handleReactionEvent — resolved msgId=\(msgId ?? "nil") (direct=\(String(describing: data["message_id"])), inner=\(String(describing: innerData?["message_id"])))")
        if let msgId {
            Task {
                logger.info("🌐 handleReactionEvent — fetching message \(msgId) from API")
                if let updated = try? await apiClient?.getChannelMessage(channelId: channelId, messageId: msgId) {
                    logger.info("✅ handleReactionEvent — API returned message, reactions=\(updated.reactions.map(\.name))")
                    if let idx = messages.firstIndex(where: { $0.id == msgId }) {
                        messages[idx] = updated
                    }
                    if let idx = threadMessages.firstIndex(where: { $0.id == msgId }) {
                        threadMessages[idx] = updated
                    }
                } else {
                    logger.error("❌ handleReactionEvent — API fetch failed for msgId=\(msgId)")
                }
            }
        } else {
            logger.error("❌ handleReactionEvent — no msgId found, cannot refresh. Full data: \(data)")
        }
    }
    
    /// Handles `message:reply` socket event — server sends the full updated parent message
    /// after a thread reply is created or deleted, updating reply_count / latest_reply_at.
    private func handleMessageReplyEvent(_ data: [String: Any]) {
        let msgData = data["data"] as? [String: Any] ?? data
        guard let msg = ChannelMessage.fromJSON(msgData) else { return }
        
        logger.debug("message:reply event for parent id=\(msg.id), reply_count=\(msg.replyCount)")
        
        withAnimation(.messageUpdate) {
            if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                messages[idx] = msg
            }
        }
        
        // If the thread for this parent is open, update the parent reference too
        if threadParentMessage?.id == msg.id {
            threadParentMessage = msg
        }
    }
    
    /// Handles `typing` socket event — shows/hides the "X is typing…" indicator.
    /// Server emits: { channel_id, message_id: null, data: { type: "typing", data: { typing: bool } }, user: { id, name } }
    private func handleTypingEvent(_ event: [String: Any]) {
        // Extract the user who is typing
        let userDict = event["user"] as? [String: Any]
        guard let userId = userDict?["id"] as? String,
              userId != currentUserId else { return } // Don't show own typing
        
        let userName = userDict?["name"] as? String ?? userId
        let data = event["data"] as? [String: Any]
        let innerData = data?["data"] as? [String: Any]
        let isTyping = innerData?["typing"] as? Bool ?? false

        // `message_id` scopes the typing event: nil = main channel, otherwise the thread parent.
        let threadId = event["message_id"] as? String
        if let threadId, !threadId.isEmpty {
            guard threadParentMessage?.id == threadId else { return }
            updateTypingList(&threadTypingUsers, userId: userId, name: userName, isTyping: isTyping, key: "t:\(userId)")
        } else {
            updateTypingList(&typingUsers, userId: userId, name: userName, isTyping: isTyping, key: "c:\(userId)")
        }
    }

    /// Adds/removes a typing user and (re)starts a single 5s expiry per user —
    /// matches the web client's clearTimeout/setTimeout pattern (no flicker).
    private func updateTypingList(_ list: inout [TypingUser], userId: String, name: String, isTyping: Bool, key: String) {
        typingExpiryTasks[key]?.cancel()
        if isTyping {
            if !list.contains(where: { $0.id == userId }) {
                list.append(TypingUser(id: userId, name: name))
            }
            let isThread = key.hasPrefix("t:")
            typingExpiryTasks[key] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                if isThread {
                    self.threadTypingUsers.removeAll { $0.id == userId }
                } else {
                    self.typingUsers.removeAll { $0.id == userId }
                }
                self.typingExpiryTasks[key] = nil
            }
        } else {
            list.removeAll { $0.id == userId }
            typingExpiryTasks[key] = nil
        }
    }

    /// Clears a typing indicator for a user once their message arrives (web parity).
    private func clearTyping(for userId: String, inThread: Bool) {
        let key = inThread ? "t:\(userId)" : "c:\(userId)"
        typingExpiryTasks[key]?.cancel()
        typingExpiryTasks[key] = nil
        if inThread { threadTypingUsers.removeAll { $0.id == userId } }
        else { typingUsers.removeAll { $0.id == userId } }
    }
    
    /// Emits a typing indicator to the server for this channel.
    /// Call this when the user types in the input field.
    func emitTyping() {
        emitTyping(threadId: nil)
    }

    /// Emits typing for the open thread (scoped by the thread parent's message id).
    func emitThreadTyping() {
        guard let parentId = threadParentMessage?.id else { return }
        emitTyping(threadId: parentId)
    }

    private func emitTyping(threadId: String?) {
        guard socketService != nil else { return }
        // Throttle: the web emits per keystroke; 1/sec is enough for a 5s expiry window.
        let key = threadId ?? ""
        let now = Date()
        if let last = lastTypingEmit[key], now.timeIntervalSince(last) < 1 { return }
        lastTypingEmit[key] = now
        socketService?.emit("events:channel", data: [
            "channel_id": channelId,
            "message_id": threadId.map { $0 as Any } ?? NSNull(),
            "data": [
                "type": "typing",
                "data": ["typing": true]
            ]
        ])
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
    
    // MARK: - Read State
    
    /// Emits the `events:channel` socket event with `type: last_read_at`.
    /// This tells the server to reset `unread_count` for the current user in this channel,
    /// matching the behaviour of OpenWebUI's web client (Channel.svelte → updateLastReadAt).
    func markAsRead() {
        guard socketService != nil else { return }
        socketService?.emit("events:channel", data: [
            "channel_id": channelId,
            "message_id": NSNull(),
            "data": ["type": "last_read_at"]
        ])
        logger.debug("Emitted last_read_at for channel \(self.channelId)")
    }
    
    // MARK: - Cleanup
    
    func cleanup() {
        // Emit last_read_at on leave so the server is up-to-date
        markAsRead()
        channelSubscription?.dispose()
        channelSubscription = nil
        typingExpiryTasks.values.forEach { $0.cancel() }
        typingExpiryTasks = [:]
        memberSearchTask?.cancel()
        // Note: Do NOT call updateMemberActiveStatus(isActive: false) here.
        // That API tells the server the user has left/hidden the channel,
        // causing DMs to disappear from the sidebar. It should only be
        // called for explicit "Leave Conversation" actions, not on navigation.
    }
}
