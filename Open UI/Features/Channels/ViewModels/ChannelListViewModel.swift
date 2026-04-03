import Foundation
import os.log

/// Manages the list of channels the current user can access.
/// Handles fetching, creating, deleting, and real-time updates.
@MainActor @Observable
final class ChannelListViewModel {
    // MARK: - Published State
    
    var channels: [Channel] = []
    var isLoading: Bool = false
    var errorMessage: String?
    var searchText: String = ""
    var showCreateSheet: Bool = false
    
    /// The channel ID the user is currently viewing. When set, incoming socket
    /// messages for that channel do NOT increment the local unread count.
    var activeChannelId: String?
    
    // MARK: - Computed
    
    var filteredChannels: [Channel] {
        let visible = channels.filter { !$0.isHiddenDM }
        if searchText.isEmpty { return visible }
        let query = searchText.lowercased()
        return visible.filter { channel in
            if channel.name.lowercased().contains(query) { return true }
            if channel.description?.lowercased().contains(query) == true { return true }
            if channel.type == .dm {
                return channel.dmParticipants.contains { participant in
                    participant.displayName.lowercased().contains(query)
                    || participant.email.lowercased().contains(query)
                }
            }
            return false
        }
    }
    
    /// Standard channels (non-DM, non-group).
    var standardChannels: [Channel] {
        filteredChannels.filter { $0.type == .standard }
    }
    
    /// Group channels.
    var groupChannels: [Channel] {
        filteredChannels.filter { $0.type == .group }
    }
    
    /// Direct message channels.
    var dmChannels: [Channel] {
        filteredChannels.filter { $0.type == .dm }
    }
    
    /// Whether there are any channels in any category.
    var hasChannels: Bool {
        !channels.isEmpty
    }
    
    // MARK: - Private
    
    private var apiClient: APIClient?
    private var socketService: SocketIOService?
    private var channelSubscription: SocketSubscription?
    private let logger = Logger(subsystem: "com.openui", category: "ChannelList")
    private(set) var hasLoaded = false
    
    /// Current user ID — needed to filter DM participants (exclude self).
    var currentUserId: String?
    
    /// All server users — cached for the "New DM" picker.
    /// BUG-007 fix: Track when last fetched for cache invalidation.
    var allServerUsers: [ChannelMember] = []
    var isLoadingUsers = false
    private var usersLoadedAt: Date?
    private let usersCacheTimeout: TimeInterval = 300 // 5 minutes
    
    // MARK: - Configuration
    
    func configure(apiClient: APIClient, socket: SocketIOService?, currentUserId: String? = nil) {
        self.apiClient = apiClient
        self.socketService = socket
        self.currentUserId = currentUserId
    }
    
    // MARK: - Loading
    
    func loadChannels() async {
        guard let apiClient else { return }
        if !hasLoaded { isLoading = true }
        errorMessage = nil
        
        do {
            let fetched = try await apiClient.getChannels()
            channels = fetched.sorted { $0.updatedAt > $1.updatedAt }
            await populateDMParticipants()
            hasLoaded = true
        } catch {
            logger.error("Failed to load channels: \(error.localizedDescription)")
            if !hasLoaded {
                errorMessage = "Failed to load channels: \(error.localizedDescription)"
            }
        }
        
        isLoading = false
    }
    
    func refreshChannels() async {
        await loadChannels()
    }
    
    /// Loads all server users for the "New DM" and member pickers.
    /// BUG-007 fix: Force-refresh after cache timeout.
    func loadAllServerUsers(forceRefresh: Bool = false) async {
        guard let apiClient else { return }
        
        // Return cached if within timeout and not force-refreshing
        if !forceRefresh, !allServerUsers.isEmpty,
           let loadedAt = usersLoadedAt,
           Date().timeIntervalSince(loadedAt) < usersCacheTimeout {
            return
        }
        
        isLoadingUsers = true
        do {
            allServerUsers = try await apiClient.searchUsers()
            usersLoadedAt = Date()
            logger.info("Loaded \(self.allServerUsers.count) server users for pickers")
        } catch {
            logger.warning("Failed to load server users: \(error.localizedDescription)")
        }
        isLoadingUsers = false
    }
    
    // MARK: - DM Support
    
    /// Populates `dmParticipants` on each DM channel.
    /// Skips channels that already have participant data to avoid unnecessary network requests
    /// and prevent avatar flicker when re-opening the channels list.
    private func populateDMParticipants() async {
        guard let apiClient else { return }
        // Only fetch for DM channels that don't yet have participant data
        let dmChannelIndices = channels.enumerated().compactMap { (idx, ch) -> Int? in
            guard ch.type == .dm, ch.dmParticipants.isEmpty else { return nil }
            return idx
        }
        guard !dmChannelIndices.isEmpty else { return }
        
        await withTaskGroup(of: (String, [ChannelMember]).self) { group in
            for idx in dmChannelIndices {
                let channelId = channels[idx].id
                group.addTask {
                    let members = (try? await apiClient.getChannelMembers(id: channelId)) ?? []
                    return (channelId, members)
                }
            }
            for await (channelId, members) in group {
                if let idx = channels.firstIndex(where: { $0.id == channelId }) {
                    channels[idx].dmParticipants = members.filter { $0.id != self.currentUserId }
                }
            }
        }
    }
    
    /// Starts a DM conversation with a user.
    func startDMWith(userId: String) async -> Channel? {
        guard let apiClient else { return nil }
        
        if let existing = channels.first(where: { ch in
            ch.type == .dm && ch.dmParticipants.contains(where: { $0.id == userId })
        }) {
            // MF-001: Un-hide if hidden
            if existing.isHiddenDM, let idx = channels.firstIndex(where: { $0.id == existing.id }) {
                channels[idx].isHiddenDM = false
            }
            return existing
        }
        
        do {
            if let channel = try await apiClient.getDMChannel(userId: userId) {
                if !channels.contains(where: { $0.id == channel.id }) {
                    channels.insert(channel, at: 0)
                }
                await populateDMParticipants()
                return channels.first(where: { $0.id == channel.id })
            }
            
            // Match web UI: DM creation sends name="" and is_private=null
            let newChannel = try await apiClient.createChannel(
                name: "",
                type: "dm",
                userIds: [userId]
            )
            // No need for separate addChannelMembers — userIds is handled by the create endpoint
            channels.insert(newChannel, at: 0)
            await populateDMParticipants()
            return channels.first(where: { $0.id == newChannel.id })
        } catch {
            logger.error("Failed to start DM with \(userId): \(error.localizedDescription)")
            errorMessage = "Failed to start conversation."
            return nil
        }
    }
    
    /// MF-001: Hides a DM from the sidebar (preserves message history).
    func hideDM(channelId: String) {
        if let idx = channels.firstIndex(where: { $0.id == channelId }) {
            channels[idx].isHiddenDM = true
        }
    }
    
    /// MF-001: Un-hides a DM (called when new message arrives in hidden DM).
    func unhideDM(channelId: String) {
        if let idx = channels.firstIndex(where: { $0.id == channelId && $0.isHiddenDM }) {
            channels[idx].isHiddenDM = false
        }
    }
    
    // MARK: - Create Channel
    
    func createChannel(
        name: String,
        description: String? = nil,
        type: ChannelType = .standard,
        isPrivate: Bool = false,
        userIds: [String] = [],
        groupIds: [String] = []
    ) async -> Channel? {
        guard let apiClient else { return nil }
        
        let normalizedName = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // DMs can have empty names (server uses participant names for display)
        guard type == .dm || !normalizedName.isEmpty else {
            errorMessage = "Channel name cannot be empty."
            return nil
        }
        
        let wireType: String
        switch type {
        case .dm: wireType = "dm"
        case .group: wireType = "group"
        case .standard: wireType = ""
        }
        
        let wirePrivate: Bool? = (type == .dm) ? nil : isPrivate
        
        do {
            let channel = try await apiClient.createChannel(
                name: normalizedName,
                description: description,
                type: wireType,
                isPrivate: wirePrivate,
                groupIds: groupIds.isEmpty ? nil : groupIds,
                userIds: userIds.isEmpty ? nil : userIds
            )
            
            channels.insert(channel, at: 0)
            logger.info("Created channel: \(channel.name)")
            return channel
        } catch {
            logger.error("Failed to create channel: \(error.localizedDescription)")
            errorMessage = "Failed to create channel: \(error.localizedDescription)"
            return nil
        }
    }
    
    // MARK: - Delete Channel
    
    func deleteChannel(id: String) async {
        guard let apiClient else { return }
        
        let removedIndex = channels.firstIndex(where: { $0.id == id })
        let removedChannel = removedIndex.map { channels[$0] }
        if let idx = removedIndex {
            channels.remove(at: idx)
        }
        
        do {
            try await apiClient.deleteChannel(id: id)
            logger.info("Deleted channel: \(id)")
        } catch {
            if let channel = removedChannel, let idx = removedIndex {
                channels.insert(channel, at: min(idx, channels.count))
            }
            logger.error("Failed to delete channel: \(error.localizedDescription)")
            errorMessage = "Failed to delete channel."
        }
    }
    
    // MARK: - Update Channel
    
    func updateChannel(id: String, name: String?, description: String?) async {
        guard let apiClient else { return }
        
        do {
            let updated = try await apiClient.updateChannel(id: id, name: name, description: description)
            if let idx = channels.firstIndex(where: { $0.id == id }) {
                channels[idx] = updated
            }
        } catch {
            logger.error("Failed to update channel: \(error.localizedDescription)")
            errorMessage = "Failed to update channel."
        }
    }
    
    // MARK: - Socket Events (PERF-002: Targeted updates, not full refresh)
    
    func startSocketListener() {
        guard let socket = socketService, socket.isConnected else { return }
        
        channelSubscription?.dispose()
        channelSubscription = socket.addChannelEventHandler { [weak self] event, _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleChannelEvent(event)
            }
        }
    }
    
    func stopSocketListener() {
        channelSubscription?.dispose()
        channelSubscription = nil
    }
    
    // MARK: - Unread Count Management
    
    /// Immediately zeroes the unread count for a channel locally.
    /// Call this when the user opens a channel so the badge clears instantly
    /// without waiting for the next server refresh.
    func markChannelRead(id: String) {
        if let idx = channels.firstIndex(where: { $0.id == id }) {
            channels[idx].unreadCount = 0
        }
    }
    
    private func handleChannelEvent(_ event: [String: Any]) {
        let data = event["data"] as? [String: Any] ?? event
        let rawType = data["type"] as? String
        let eventType = ChannelSocketEventType.from(rawType)
        
        switch eventType {
        case .message, .channelMessage, .channelMessageNew:
            // PERF-002: Targeted update instead of full refresh
            // Extract channel_id from the event and update only that channel
            let channelId: String? = {
                if let id = data["channel_id"] as? String { return id }
                if let msgData = data["data"] as? [String: Any] {
                    return msgData["channel_id"] as? String
                }
                return nil
            }()
            
            if let channelId {
                // Update the specific channel's timestamp and move to top
                if let idx = channels.firstIndex(where: { $0.id == channelId }) {
                    channels[idx].updatedAt = .now
                    
                    // Only increment unread when the user is NOT actively viewing this channel.
                    // If they have the channel open, the read state is handled by ChannelViewModel.markAsRead().
                    if activeChannelId != channelId {
                        channels[idx].unreadCount += 1

                        // Fire a local push notification for the new message.
                        let channel = channels[idx]
                        let msgData: [String: Any] = {
                            if let d = data["data"] as? [String: Any] { return d }
                            return data
                        }()
                        let senderName: String = {
                            if let user = msgData["user"] as? [String: Any],
                               let name = user["name"] as? String, !name.isEmpty { return name }
                            if let name = msgData["user_name"] as? String, !name.isEmpty { return name }
                            return "New message"
                        }()
                        let preview: String = {
                            if let content = msgData["content"] as? String {
                                return String(content.prefix(80))
                            }
                            return ""
                        }()
                        let userId = msgData["user_id"] as? String ?? (msgData["user"] as? [String: Any])?["id"] as? String
                        // Don't notify for own messages
                        if userId != currentUserId {
                            let channelDisplayName: String = {
                                if channel.type == .dm {
                                    let participants = channel.dmParticipants
                                    if !participants.isEmpty {
                                        return participants.map { $0.displayName }.joined(separator: ", ")
                                    }
                                    return channel.name.isEmpty ? "Direct Message" : channel.name
                                }
                                return "#\(channel.name)"
                            }()
                            Task {
                                await NotificationService.shared.notifyChannelMessage(
                                    channelId: channelId,
                                    channelName: channelDisplayName,
                                    senderName: senderName,
                                    preview: preview
                                )
                            }
                        }
                    }
                    
                    // MF-001: Un-hide DM if new message arrives
                    if channels[idx].type == .dm && channels[idx].isHiddenDM {
                        channels[idx].isHiddenDM = false
                    }
                    
                    // Move to top
                    let channel = channels.remove(at: idx)
                    channels.insert(channel, at: 0)
                }
            } else {
                // Fallback: refresh all (only if we can't determine the channel)
                Task { await refreshChannels() }
            }
            
        default:
            break
        }
    }
}
