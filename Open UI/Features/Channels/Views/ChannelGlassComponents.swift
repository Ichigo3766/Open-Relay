import SwiftUI

// MARK: - Channel Glass Components
//
// Shared building blocks for the Liquid Glass channel experience (iPhone + iPad,
// main timeline + threads). All glass uses `chatControlGlass` so iOS < 26 falls
// back to frosted material automatically.

// MARK: - Avatar URL Resolution

enum ChannelAvatarURL {
    /// Webhook senders use the webhook avatar endpoint (web parity); users use their profile image.
    static func forSender(userId: String, isWebhook: Bool, serverBaseURL: String) -> URL? {
        guard !userId.isEmpty, !serverBaseURL.isEmpty else { return nil }
        if isWebhook {
            return URL(string: "\(serverBaseURL)/api/v1/channels/webhooks/\(userId)/profile/image")
        }
        return URL(string: "\(serverBaseURL)/api/v1/users/\(userId)/profile/image")
    }
}

// MARK: - Reactions Bar

/// Glass reaction chips. Own reactions are tinted; long-press shows who reacted.
struct ChannelReactionsBar: View {
    let reactions: [MessageReaction]
    let currentUserId: String?
    var alignment: HorizontalAlignment = .leading
    var isEnabled: Bool = true
    let onToggle: (String) -> Void
    let onAdd: () -> Void
    var onShowReactors: ((MessageReaction) -> Void)? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        ChannelFlowLayout(spacing: 4, alignment: alignment) {
            ForEach(reactions) { reaction in
                chip(reaction)
            }
            if isEnabled {
                Button {
                    onAdd()
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "face.smiling")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .chatControlGlass(in: Circle(), fallback: theme.surfaceContainer.opacity(0.5))
                .accessibilityLabel("Add reaction")
            }
        }
    }

    @ViewBuilder
    private func chip(_ reaction: MessageReaction) -> some View {
        let isOwn = reaction.userIds.contains(currentUserId ?? "")
        let label = HStack(spacing: 3) {
            Text(reaction.name.emojiFromShortcode)
                .font(.system(size: 13))
            if reaction.count > 0 {
                Text("\(reaction.count)")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(isOwn ? theme.brandPrimary : theme.textSecondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)

        Button {
            guard isEnabled else { return }
            onToggle(reaction.name)
        } label: {
            if isOwn {
                label.chatTintedGlass(in: Capsule(), tint: theme.brandPrimary)
            } else {
                label.chatControlGlass(in: Capsule(), fallback: theme.surfaceContainer.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                onShowReactors?(reaction)
            }
        )
        .accessibilityLabel("\(reaction.name.emojiFromShortcode) \(reaction.count)")
        .accessibilityHint(isOwn ? "Remove your reaction" : "Add this reaction")
    }
}

/// Minimal wrapping layout for reaction chips.
struct ChannelFlowLayout: Layout {
    var spacing: CGFloat = 4
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(maxWidth: maxWidth, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x: CGFloat
            switch alignment {
            case .trailing: x = bounds.maxX - row.width
            case .center: x = bounds.minX + (bounds.width - row.width) / 2
            default: x = bounds.minX
            }
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            let last = rows.count - 1
            let extra = rows[last].indices.isEmpty ? size.width : size.width + spacing
            if rows[last].width + extra > maxWidth, !rows[last].indices.isEmpty {
                rows.append(Row())
            }
            let cur = rows.count - 1
            let isFirst = rows[cur].indices.isEmpty
            rows[cur].indices.append(i)
            rows[cur].width += isFirst ? size.width : size.width + spacing
            rows[cur].height = max(rows[cur].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

// MARK: - Typing Capsule

/// Floating glass "Alice is typing…" capsule shown above the composer.
struct ChannelTypingCapsule: View {
    let names: [String]
    @Environment(\.theme) private var theme

    private var label: String {
        let n = Array(names.prefix(3))
        switch n.count {
        case 0: return ""
        case 1: return "\(n[0]) is typing…"
        case 2: return "\(n[0]) and \(n[1]) are typing…"
        default: return "\(n[0]), \(n[1]) and others are typing…"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            TypingDotsView()
            Text(label)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .chatControlGlass(in: Capsule(), fallback: .ultraThinMaterial)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Read-Only Banner

struct ChannelReadOnlyBanner: View {
    var text: String = "You do not have permission to send messages in this channel."
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
                .scaledFont(size: 13, weight: .medium)
            Text(text)
                .scaledFont(size: 13, weight: .medium)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(theme.textTertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .chatControlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), fallback: .ultraThinMaterial)
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

// MARK: - Sidebar Row Helpers (shared by MainChatView + iPadMainChatView)

enum ChannelSidebarFormat {
    /// Compact unread count like the web sidebar ("1.2K").
    static func unread(_ count: Int) -> String {
        count < 1000 ? "\(count)" : count.formatted(.number.notation(.compactName))
    }
}

/// Italic DM status (emoji + message) shown after the name in sidebar rows (web ChannelItem).
struct ChannelSidebarStatus: View {
    let member: ChannelMember?
    @Environment(\.theme) private var theme

    var body: some View {
        if let member, member.hasStatus {
            HStack(spacing: 3) {
                if let emoji = member.statusEmojiCharacter {
                    Text(emoji).font(.system(size: 11))
                }
                if let msg = member.statusMessage, !msg.isEmpty {
                    Text(msg)
                        .scaledFont(size: 12, context: .list)
                        .italic()
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(-1)
        }
    }
}

// MARK: - Delete Confirmation

/// "Delete Message — Are you sure?" confirmation shared by the timeline and threads.
struct ChannelDeleteConfirmation: ViewModifier {
    @Bindable var viewModel: ChannelViewModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete Message",
            isPresented: Binding(
                get: { viewModel.pendingDeleteMessage != nil },
                set: { if !$0 { viewModel.pendingDeleteMessage = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let message = viewModel.pendingDeleteMessage else { return }
                viewModel.pendingDeleteMessage = nil
                Haptics.play(.medium)
                Task { await viewModel.deleteMessage(id: message.id) }
            }
            Button("Cancel", role: .cancel) { viewModel.pendingDeleteMessage = nil }
        } message: {
            Text("Are you sure you want to delete this message?")
        }
    }
}

// MARK: - Shared Message Styling (timeline + threads)

enum ChannelLayout {
    /// Consistent max bubble width: 75% on iPhone, capped on wide iPad layouts.
    static var maxBubbleWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.75, 560)
    }
}

/// Bubble surface: tinted brand fill for own messages; quiet surface with a hairline
/// border for others. Tail only on the last message of a group.
struct ChannelBubbleStyle: ViewModifier {
    let isCurrentUser: Bool
    let showTail: Bool
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = ChannelBubbleShape(isCurrentUser: isCurrentUser, showTail: showTail)
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                if isCurrentUser {
                    shape.fill(LinearGradient(
                        colors: [theme.brandPrimary.opacity(0.92), theme.brandPrimary],
                        startPoint: .top, endPoint: .bottom
                    ))
                } else {
                    shape.fill(theme.isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.045))
                }
            }
            .overlay {
                shape.strokeBorder(
                    isCurrentUser ? Color.white.opacity(theme.isDark ? 0.08 : 0.18)
                                  : (theme.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)),
                    lineWidth: 0.5
                )
            }
            .frame(minWidth: 44, maxWidth: ChannelLayout.maxBubbleWidth,
                   alignment: isCurrentUser ? .trailing : .leading)
    }
}

/// Small uppercase badge used for BOT / WEBHOOK / OP.
struct ChannelBadge: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .scaledFont(size: 8.5, weight: .bold)
            .tracking(0.3)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Quiet meta line under a bubble: time, pinned marker, edited.
struct ChannelMessageMeta: View {
    var time: String?
    var isPinned: Bool
    var isEdited: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            if isPinned {
                Label("Pinned", systemImage: "pin.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color.orange)
            }
            if let time {
                Text(time).foregroundStyle(theme.textTertiary)
            }
        }
        .scaledFont(size: 10, weight: .medium)
    }
}

/// Centered glass capsule date separator ("Today", "Yesterday", "Mon, Sep 28").
struct ChannelDateCapsule: View {
    let date: Date
    @Environment(\.theme) private var theme

    private var label: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if cal.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        Text(label)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .chatControlGlass(in: Capsule(), fallback: .ultraThinMaterial)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Thread Badge

/// Glass capsule under a message: stacked replier avatars, "N replies", last reply time.
struct ChannelThreadBadge: View {
    let replyCount: Int
    let latestReplyAt: Date?
    var avatarURLs: [URL] = []
    var authToken: String?
    let onTap: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                if avatarURLs.isEmpty {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.brandPrimary)
                } else {
                    HStack(spacing: -6) {
                        ForEach(Array(avatarURLs.prefix(3).enumerated()), id: \.offset) { _, url in
                            UserAvatar(size: 18, imageURL: url, name: nil, authToken: authToken)
                                .overlay(Circle().stroke(theme.background, lineWidth: 1.5))
                        }
                    }
                }
                Text("\(replyCount) \(replyCount == 1 ? "reply" : "replies")")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                if let latestReplyAt {
                    Text(latestReplyAt.chatTimestamp)
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                }
                Image(systemName: "chevron.right")
                    .scaledFont(size: 9, weight: .bold)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .chatControlGlass(in: Capsule(), fallback: theme.brandPrimary.opacity(0.08))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(replyCount) \(replyCount == 1 ? "reply" : "replies"), open thread")
    }
}

// MARK: - Sidebar Row (shared by MainChatView + iPadMainChatView)

/// Channel / group / DM row label for the sidebar: fixed-size leading icon or
/// avatar with presence ring, name + DM status, compact unread badge, and a
/// soft highlight when active.
struct ChannelSidebarRowLabel: View {
    let channel: Channel
    let isActive: Bool
    let serverBaseURL: String
    let authToken: String?
    /// When false, the caller supplies the outer horizontal inset
    /// (e.g. via `sidebarNestedRow()`), so the row can be indented.
    var appliesOuterPadding: Bool = true
    @Environment(\.theme) private var theme

    private var dmPartner: ChannelMember? {
        channel.type == .dm && channel.dmParticipants.count == 1 ? channel.dmParticipants.first : nil
    }

    private var title: String {
        channel.type == .dm ? (channel.dmParticipants.first?.displayName ?? channel.displayName) : channel.displayName
    }

    var body: some View {
        HStack(spacing: 8) {
            leading
                .frame(width: 24, height: 24)
            Text(title)
                .scaledFont(size: 14, context: .list)
                .fontWeight(isActive || channel.unreadCount > 0 ? .semibold : .regular)
                .foregroundStyle(isActive || channel.unreadCount > 0 ? theme.textPrimary : theme.textSecondary)
                .lineLimit(1)
            ChannelSidebarStatus(member: dmPartner)
            Spacer(minLength: 4)
            if channel.unreadCount > 0 && !isActive {
                Text(ChannelSidebarFormat.unread(channel.unreadCount))
                    .scaledFont(size: 11, weight: .bold, context: .list)
                    .foregroundStyle(theme.brandOnPrimary)
                    .padding(.horizontal, 7)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(theme.brandPrimary, in: Capsule())
                    .accessibilityLabel("\(channel.unreadCount) unread")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.brandPrimary.opacity(theme.isDark ? 0.16 : 0.1))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, appliesOuterPadding ? 6 : 0)
    }

    @ViewBuilder
    private var leading: some View {
        if channel.type == .dm, let participant = channel.dmParticipants.first {
            UserAvatar(
                size: 24,
                imageURL: participant.resolveAvatarURL(serverBaseURL: serverBaseURL),
                name: participant.displayName,
                authToken: authToken
            )
            .overlay(alignment: .bottomTrailing) {
                if dmPartner != nil {
                    Circle()
                        .fill(participant.isOnline ? Color.green : Color.gray.opacity(0.55))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(theme.sidebarBackground, lineWidth: 1.5))
                        .offset(x: 1, y: 1)
                }
            }
        } else {
            Image(systemName: channel.sidebarIcon)
                .scaledFont(size: 12, weight: .semibold, context: .list)
                .foregroundStyle(isActive ? theme.brandPrimary : theme.textTertiary)
                .frame(width: 24, height: 24)
                .background((isActive ? theme.brandPrimary : theme.textTertiary).opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

// MARK: - Channel Type Card (create sheet)

struct ChannelTypeCard: View {
    let type: ChannelType
    let title: String
    let subtitle: String
    let icon: String
    @Binding var selection: ChannelType
    @Environment(\.theme) private var theme

    private var isSelected: Bool { selection == type }

    var body: some View {
        Button {
            Haptics.play(.light)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = type }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundStyle(isSelected ? theme.brandPrimary : theme.textSecondary)
                    .frame(height: 24)
                Text(title)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Text(subtitle)
                    .scaledFont(size: 10.5)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? theme.brandPrimary.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? theme.brandPrimary.opacity(0.6) : Color.clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
