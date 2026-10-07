import SwiftUI

/// Blue unread dot shown before a chat title (web ChatItem: `size-1.5 bg-sky-500`).
/// A tiny child view so @Observable tracks the read state / streaming chat per row.
struct ChatUnreadDot: View {
    let conversation: Conversation
    let activeChatStore: ActiveChatStore

    private var isUnread: Bool {
        ChatReadState.shared.isUnread(conversation, isGenerating: activeChatStore.isStreaming(conversation.id))
    }

    var body: some View {
        if isUnread {
            Circle()
                .fill(Color(red: 0.05, green: 0.65, blue: 0.91))
                .frame(width: 6, height: 6)
                .accessibilityLabel("Unread")
                .transition(.opacity)
        }
    }
}

/// Folder unread badge (web RecursiveFolder: compact count, hidden for shared folders).
struct FolderUnreadBadge: View {
    let folder: ChatFolder

    var body: some View {
        let count = ChatReadState.shared.folderUnreadCount(folder)
        if count > 0 {
            Text(count.formatted(.number.notation(.compactName)))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(red: 0.01, green: 0.52, blue: 0.78))
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(Color(red: 0.05, green: 0.65, blue: 0.91).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityLabel("\(count) unread")
        }
    }
}

/// "Mark All as Read" (web Sidebar Chats menu → POST /chats/read).
struct MarkAllReadMenuItem: View {
    let conversations: [Conversation]
    let apiClient: APIClient?

    var body: some View {
        if let apiClient {
            Button {
                Task {
                    do {
                        try await ChatReadState.shared.markAllRead(conversations, api: apiClient)
                        Haptics.notify(.success)
                    } catch {
                        Haptics.notify(.error)
                    }
                }
            } label: {
                Label("Mark All as Read", systemImage: "checkmark.circle")
            }
        }
    }
}

/// "…" button on the Chats section heading (web Sidebar: Chats "More" menu → Mark all as read).
/// Shown over the heading's trailing edge, beside — not inside — the collapse button.
struct ChatsHeaderMoreMenu: View {
    let conversations: [Conversation]
    let folders: [ChatFolder]
    let apiClient: APIClient?
    @Environment(\.theme) private var theme

    private static func allChats(_ f: ChatFolder) -> [Conversation] {
        f.chats + f.childFolders.flatMap { allChats($0) }
    }

    var body: some View {
        Menu {
            // Not gated on unread state: lists can be partial, and the server call is cheap.
            MarkAllReadMenuItem(
                conversations: conversations + folders.flatMap { Self.allChats($0) },
                apiClient: apiClient)
        } label: {
            Image(systemName: "ellipsis")
                .scaledFont(size: 12, weight: .semibold, context: .list)
                .foregroundStyle(theme.textTertiary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }
}

/// "Mark All as Read" for one folder (web FolderMenu → POST /folders/{id}/read).
struct MarkFolderReadMenuItem: View {
    let folder: ChatFolder
    let apiClient: APIClient?

    var body: some View {
        if let apiClient, ChatReadState.shared.folderUnreadCount(folder) > 0 {
            Button {
                Task {
                    do {
                        try await ChatReadState.shared.markFolderRead(folder.id, chats: Self.allChats(folder), api: apiClient)
                        Haptics.notify(.success)
                    } catch {
                        Haptics.notify(.error)
                    }
                }
            } label: {
                Label("Mark All as Read", systemImage: "checkmark.circle")
            }
        }
    }

    private static func allChats(_ f: ChatFolder) -> [Conversation] {
        f.chats + f.childFolders.flatMap { allChats($0) }
    }
}

/// "Mark as Unread" for a chat's context menu (web ChatMenu). Hidden for the open chat
/// (it would be marked read again straight away) and for temporary chats.
struct MarkUnreadMenuItem: View {
    let conversation: Conversation
    let apiClient: APIClient?
    var isOpen: Bool = false

    var body: some View {
        if !isOpen, !conversation.isTemporary, let apiClient,
           !ChatReadState.shared.isUnread(conversation) {
            Button {
                Task {
                    do {
                        try await ChatReadState.shared.markUnread(conversation.id, api: apiClient)
                        Haptics.play(.light)
                    } catch {
                        Haptics.notify(.error)
                    }
                }
            } label: {
                Label("Mark as Unread", systemImage: "circlebadge")
            }
        }
    }
}
