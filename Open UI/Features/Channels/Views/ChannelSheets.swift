import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Channel Sheets
//
// Members, pinned messages, profile card and webhooks — ports of the web's
// ChannelInfoModal/UserList, PinnedMessagesModal, UserStatus and WebhooksModal.

// MARK: - Members Sheet

/// Server-paginated, searchable member list (web: ChannelInfoModal → UserList).
/// Group managers can add members (users or whole groups) and remove members.
struct ChannelMembersSheet: View {
    @Bindable var viewModel: ChannelViewModel
    var onShowProfile: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @State private var searchText = ""
    @State private var showAddMembers = false
    @State private var isAdding = false
    @State private var memberToRemove: ChannelMember?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            memberList
                .listStyle(.insetGrouped)
                .searchable(text: $searchText, prompt: "Search members")
                .onChange(of: searchText) { _, q in viewModel.searchMembers(q) }
                .navigationTitle(viewModel.isDM ? "Participants" : "Members")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                    }
                    if viewModel.canManageMembers {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Add Members", systemImage: "person.badge.plus") {
                                Task { await viewModel.loadAllServerUsers() }
                                showAddMembers = true
                            }
                        }
                    }
                }
                .sheet(isPresented: $showAddMembers) { addMembersSheet }
                .confirmationDialog(
                    "Remove \(memberToRemove?.displayName ?? "member") from this channel?",
                    isPresented: Binding(get: { memberToRemove != nil }, set: { if !$0 { memberToRemove = nil } }),
                    titleVisibility: .visible
                ) {
                    Button("Remove", role: .destructive) { removeSelected() }
                }
                .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "")
                }
        }
    }

    private var memberList: some View {
        List {
            if viewModel.memberSearchResults.isEmpty && viewModel.isLoadingMemberPage {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if viewModel.memberSearchResults.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(viewModel.memberSearchResults) { member in
                        memberRow(member)
                            .contentShape(Rectangle())
                            .onTapGesture { onShowProfile(member.id) }
                            .swipeActions(edge: .trailing) {
                                if viewModel.canManageMembers && member.id != viewModel.currentUserId {
                                    Button("Remove", role: .destructive) { memberToRemove = member }
                                }
                            }
                            .onAppear {
                                if member.id == viewModel.memberSearchResults.last?.id {
                                    Task { await viewModel.loadMoreMembers() }
                                }
                            }
                    }
                    if viewModel.hasMoreMembers {
                        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    }
                } header: {
                    Text("\(viewModel.memberTotal) member\(viewModel.memberTotal == 1 ? "" : "s")")
                }
            }
        }
    }

    private var addMembersSheet: some View {
        UnifiedAddAccessSheet(
            existingUserIds: Set(viewModel.members.map(\.id)),
            existingGroupIds: [],
            allUsers: viewModel.allServerUsers,
            isLoading: isAdding,
            serverBaseURL: viewModel.serverBaseURL,
            authToken: viewModel.serverAuthToken,
            apiClient: dependencies.apiClient,
            onAdd: { userIds, groupIds in
                isAdding = true
                Task {
                    do {
                        try await viewModel.addMembers(userIds: userIds, groupIds: groupIds)
                        Haptics.notify(.success)
                        showAddMembers = false
                    } catch {
                        errorMessage = "Failed to add members: \(error.localizedDescription)"
                    }
                    isAdding = false
                }
            },
            onCancel: { showAddMembers = false }
        )
        .presentationDetents([.medium, .large])
    }

    private func removeSelected() {
        guard let member = memberToRemove else { return }
        memberToRemove = nil
        Task {
            do {
                try await viewModel.removeMember(userId: member.id)
                Haptics.notify(.success)
            } catch {
                errorMessage = "Failed to remove member: \(error.localizedDescription)"
            }
        }
    }

    private func memberRow(_ member: ChannelMember) -> some View {
        HStack(spacing: Spacing.md) {
            ZStack(alignment: .bottomTrailing) {
                UserAvatar(
                    size: 36,
                    imageURL: member.resolveAvatarURL(serverBaseURL: viewModel.serverBaseURL),
                    name: member.displayName,
                    authToken: viewModel.serverAuthToken
                )
                Circle()
                    .fill(member.isOnline ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(member.displayName)
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if member.id == viewModel.currentUserId {
                        Text("You").scaledFont(size: 11).foregroundStyle(theme.textTertiary)
                    }
                }
                if member.hasStatus {
                    Text("\(member.statusEmojiCharacter.map { "\($0) " } ?? "")\(member.statusMessage ?? "")")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                } else {
                    Text(member.email)
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            ChannelRoleBadge(role: member.role)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows profile")
    }
}

/// Role badge matching the web's Badge colours (admin=info, user=success, other=muted).
struct ChannelRoleBadge: View {
    let role: String?
    var body: some View {
        let r = (role ?? "user").lowercased()
        let color: Color = r == "admin" ? .blue : (r == "user" ? .green : .gray)
        Text(r.capitalized)
            .scaledFont(size: 10, weight: .semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Pinned Messages Sheet

/// Paginated pinned list with rich rendering, unpin, and jump-to-message
/// (web: PinnedMessagesModal).
struct PinnedMessagesSheet: View {
    @Bindable var viewModel: ChannelViewModel
    var onJump: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.pinnedMessages.isEmpty && viewModel.isLoadingPinned {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.pinnedMessages.isEmpty {
                    ContentUnavailableView {
                        Label("No pinned messages", systemImage: "pin.slash")
                    } description: {
                        Text("Long-press a message and choose Pin to keep it here.")
                    }
                } else {
                    List {
                        ForEach(viewModel.pinnedMessages) { message in
                            pinnedRow(message)
                                .contentShape(Rectangle())
                                .onTapGesture { onJump(message.id) }
                                .swipeActions(edge: .trailing) {
                                    Button {
                                        Task { await viewModel.unpinFromList(message) }
                                        Haptics.play(.light)
                                    } label: {
                                        Label("Unpin", systemImage: "pin.slash")
                                    }
                                    .tint(.orange)
                                }
                                .contextMenu {
                                    Button { onJump(message.id) } label: { Label("Go to Message", systemImage: "arrow.right.circle") }
                                    Button { viewModel.copyMessage(message) } label: { Label("Copy", systemImage: "doc.on.doc") }
                                    Button { Task { await viewModel.unpinFromList(message) } } label: { Label("Unpin", systemImage: "pin.slash") }
                                }
                                .onAppear {
                                    if message.id == viewModel.pinnedMessages.last?.id {
                                        Task { await viewModel.loadMorePinnedMessages() }
                                    }
                                }
                        }
                        if !viewModel.allPinnedLoaded && viewModel.isLoadingPinned {
                            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Pinned Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
            }
        }
    }

    private func pinnedRow(_ message: ChannelMessage) -> some View {
        let isModel = viewModel.isModelMessage(message)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if isModel, let model = viewModel.resolveModelForMessage(message) {
                    ModelAvatar(size: 22, imageURL: model.resolveAvatarURL(baseURL: viewModel.serverBaseURL),
                                label: model.shortName, authToken: viewModel.serverAuthToken)
                } else {
                    UserAvatar(
                        size: 22,
                        imageURL: ChannelAvatarURL.forSender(userId: message.userId, isWebhook: message.isFromWebhook,
                                                             serverBaseURL: viewModel.serverBaseURL),
                        name: viewModel.resolvedSenderName(for: message),
                        authToken: viewModel.serverAuthToken
                    )
                }
                Text(viewModel.resolvedSenderName(for: message))
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(isModel ? theme.mentionModelText : theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(message.createdAt.chatTimestamp)
                    .scaledFont(size: 11)
                    .foregroundStyle(theme.textTertiary)
            }
            if !message.content.isEmpty {
                ChannelMarkdownView(
                    content: message.content,
                    currentUserId: viewModel.currentUserId,
                    isCurrentUser: false,
                    accessibleChannelIds: viewModel.accessibleChannelIds
                )
                .lineLimit(6)
            } else if !message.files.isEmpty {
                Label("\(message.files.count) attachment\(message.files.count == 1 ? "" : "s")", systemImage: "paperclip")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Profile Sheet

/// Profile card: avatar, active/away, status, bio, groups and a "Message" button
/// that opens (or creates) the DM (web: ProfilePreview → UserStatus).
struct ChannelProfileSheet: View {
    let userId: String
    let viewModel: ChannelViewModel
    var onMessage: (String) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ChannelMember?
    @State private var isLoading = true
    @State private var isOpeningDM = false

    /// Best-effort placeholder from already-loaded members while the full profile loads.
    private var fallback: ChannelMember? {
        viewModel.members.first(where: { $0.id == userId })
            ?? viewModel.memberSearchResults.first(where: { $0.id == userId })
            ?? viewModel.allServerUsers.first(where: { $0.id == userId })
    }

    private var shown: ChannelMember? { profile ?? fallback }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.md) {
                    header
                    statusCard
                    detailSections
                    if userId != viewModel.currentUserId {
                        messageButton
                    }
                }
                .padding(Spacing.screenPadding)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
            }
        }
        .task {
            profile = await viewModel.loadUserProfile(userId: userId)
            isLoading = false
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        if let p = shown, p.hasStatus {
            HStack(spacing: 8) {
                if let emoji = p.statusEmojiCharacter { Text(emoji).font(.system(size: 16)) }
                Text(p.statusMessage ?? "")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .chatControlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), fallback: theme.surfaceContainer)
        }
    }

    @ViewBuilder
    private var detailSections: some View {
        if let bio = shown?.bio, !bio.isEmpty {
            infoSection(title: "About") {
                Text(bio)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if let groups = shown?.groupNames, !groups.isEmpty {
            infoSection(title: "Groups") {
                ChannelFlowLayout(spacing: 6) {
                    ForEach(groups, id: \.self) { g in
                        Text(g)
                            .scaledFont(size: 12, weight: .medium)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(theme.surfaceContainer, in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var messageButton: some View {
        Button {
            openDM()
        } label: {
            HStack {
                if isOpeningDM { ProgressView().controlSize(.small) }
                Label("Message", systemImage: "bubble.left.fill")
                    .scaledFont(size: 15, weight: .semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(isOpeningDM)
    }

    private var header: some View {
        VStack(spacing: 8) {
            UserAvatar(
                size: 84,
                imageURL: shown?.resolveAvatarURL(serverBaseURL: viewModel.serverBaseURL)
                    ?? URL(string: "\(viewModel.serverBaseURL)/api/v1/users/\(userId)/profile/image"),
                name: shown?.displayName,
                authToken: viewModel.serverAuthToken
            )
            HStack(spacing: 6) {
                Text(shown?.displayName ?? (isLoading ? "Loading…" : "Unknown user"))
                    .scaledFont(size: 20, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                if let role = shown?.role { ChannelRoleBadge(role: role) }
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(shown?.isOnline == true ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(shown?.isOnline == true ? "Active" : "Away")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textSecondary)
                if shown?.isOnline != true, let seen = shown?.lastSeenText {
                    Text("· Last seen \(seen)")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            if let local = shown?.localTimeText {
                Label("\(local) local time", systemImage: "clock")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [theme.brandPrimary.opacity(0.18), theme.brandPrimary.opacity(0.04)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .chatControlGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), fallback: Color.clear)
        .accessibilityElement(children: .combine)
    }

    private func infoSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openDM() {
        isOpeningDM = true
        Task {
            if let id = await viewModel.directMessageChannelId(with: userId) {
                Haptics.play(.light)
                onMessage(id)
            }
            isOpeningDM = false
        }
    }
}

// MARK: - Webhooks Sheet

/// Manage incoming webhooks: create, rename, change avatar, copy URL, delete
/// (web: WebhooksModal + WebhookItem). Managers only.
struct ChannelWebhooksSheet: View {
    @Bindable var viewModel: ChannelViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var expandedId: String?
    @State private var draftNames: [String: String] = [:]
    @State private var draftImages: [String: String] = [:]
    @State private var photoItem: PhotosPickerItem?
    @State private var photoTargetId: String?
    @State private var toDelete: ChannelWebhook?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var copiedId: String?

    private var hasChanges: Bool { !draftNames.isEmpty || !draftImages.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                if viewModel.isLoadingWebhooks && viewModel.webhooks.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                } else if viewModel.webhooks.isEmpty {
                    ContentUnavailableView {
                        Label("No webhooks yet", systemImage: "link.badge.plus")
                    } description: {
                        Text("Webhooks let external services post messages into this channel.")
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(viewModel.webhooks) { webhook in
                            webhookRow(webhook)
                        }
                    } footer: {
                        Text("Anyone with a webhook URL can post to this channel. Keep it secret. Copied URLs stay on this device and clear from the clipboard after five minutes.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Webhooks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if hasChanges {
                        Button("Save") { save() }.disabled(isSaving).fontWeight(.semibold)
                    }
                    Button("New Webhook", systemImage: "plus") { create() }.disabled(isSaving)
                }
            }
            .task { await viewModel.loadWebhooks() }
            .onChange(of: photoItem) { _, item in
                guard let item, let id = photoTargetId else { return }
                Task { await loadAvatar(item, for: id) }
            }
            .confirmationDialog("Delete this webhook?", isPresented: Binding(
                get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }
            ), titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteSelected() }
            } message: {
                Text("Services using its URL will no longer be able to post.")
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    @ViewBuilder
    private func webhookRow(_ webhook: ChannelWebhook) -> some View {
        let isExpanded = expandedId == webhook.id
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    expandedId = isExpanded ? nil : webhook.id
                }
            } label: {
                HStack(spacing: 12) {
                    webhookAvatar(webhook, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draftNames[webhook.id] ?? webhook.name)
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Text("Created \(webhook.createdAt.formatted(date: .abbreviated, time: .omitted))\(webhook.creatorName.map { " by \($0)" } ?? "")")
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                HStack(spacing: 12) {
                    PhotosPicker(selection: Binding(
                        get: { photoItem },
                        set: { photoTargetId = webhook.id; photoItem = $0 }
                    ), matching: .images) {
                        webhookAvatar(webhook, size: 44)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "camera.fill")
                                    .scaledFont(size: 9)
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .background(theme.brandPrimary, in: Circle())
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Change webhook avatar")

                    TextField("Webhook Name", text: Binding(
                        get: { draftNames[webhook.id] ?? webhook.name },
                        set: { draftNames[webhook.id] = $0 == webhook.name ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 10) {
                    Button {
                        // The URL is a posting secret: keep it off Universal Clipboard
                        // and expire it from the pasteboard after five minutes.
                        UIPasteboard.general.setItems(
                            [[UTType.utf8PlainText.identifier: viewModel.webhookURL(webhook)]],
                            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)]
                        )
                        Haptics.notify(.success)
                        withAnimation { copiedId = webhook.id }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { if copiedId == webhook.id { copiedId = nil } }
                        }
                    } label: {
                        Label(copiedId == webhook.id ? "Copied" : "Copy URL",
                              systemImage: copiedId == webhook.id ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        toDelete = webhook
                    } label: {
                        Label("Delete", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .scaledFont(size: 13, weight: .medium)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func webhookAvatar(_ webhook: ChannelWebhook, size: CGFloat) -> some View {
        let raw = draftImages[webhook.id] ?? webhook.profileImageURL
        if let raw, raw.hasPrefix("data:") {
            UserAvatar(size: size, name: webhook.name, dataURIString: raw)
        } else if let url = webhook.avatarURL(serverBaseURL: viewModel.serverBaseURL) {
            UserAvatar(size: size, imageURL: url, name: webhook.name, authToken: viewModel.serverAuthToken)
        } else {
            Image(systemName: "link")
                .scaledFont(size: size * 0.4, weight: .semibold)
                .foregroundStyle(theme.textSecondary)
                .frame(width: size, height: size)
                .background(theme.surfaceContainer, in: Circle())
        }
    }

    // MARK: Actions

    private func create() {
        isSaving = true
        Task {
            do {
                if let created = try await viewModel.createWebhook() {
                    withAnimation { expandedId = created.id }
                    Haptics.notify(.success)
                }
            } catch {
                errorMessage = "Failed to create webhook: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }

    private func save() {
        isSaving = true
        let ids = Set(draftNames.keys).union(draftImages.keys)
        Task {
            do {
                for id in ids {
                    guard let webhook = viewModel.webhooks.first(where: { $0.id == id }) else { continue }
                    try await viewModel.updateWebhook(
                        webhook,
                        name: draftNames[id] ?? webhook.name,
                        profileImageURL: draftImages[id] ?? webhook.profileImageURL
                    )
                }
                draftNames = [:]
                draftImages = [:]
                Haptics.notify(.success)
            } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }

    private func deleteSelected() {
        guard let webhook = toDelete else { return }
        toDelete = nil
        Task {
            do {
                try await viewModel.deleteWebhook(webhook)
                draftNames[webhook.id] = nil
                draftImages[webhook.id] = nil
                Haptics.notify(.success)
            } catch {
                errorMessage = "Failed to delete webhook: \(error.localizedDescription)"
            }
        }
    }

    /// Crops/resizes to 100×100 and encodes as a data URL (matches web WebhookItem).
    private func loadAvatar(_ item: PhotosPickerItem, for id: String) async {
        defer { photoItem = nil; photoTargetId = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        let side: CGFloat = 100
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let scaled = renderer.image { _ in
            let aspect = image.size.width / max(image.size.height, 1)
            let w = aspect > 1 ? side * aspect : side
            let h = aspect > 1 ? side : side / aspect
            image.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
        guard let jpeg = scaled.jpegData(compressionQuality: 0.8) else { return }
        draftImages[id] = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }
}
