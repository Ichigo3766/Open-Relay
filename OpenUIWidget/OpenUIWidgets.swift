import WidgetKit
import SwiftUI

// MARK: - Recent Chats Widget

/// A widget that displays recent conversations on the home screen.
struct RecentChatsWidget: Widget {
    let kind: String = "RecentChatsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecentChatsProvider()) { entry in
            RecentChatsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Recent Chats")
        .description("View your recent conversations and jump back in quickly.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Timeline Provider

struct RecentChatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentChatsEntry {
        RecentChatsEntry(
            date: .now,
            conversations: [
                .init(id: "1", title: "Planning meeting notes", lastMessage: "Let me help you with that...", updatedAt: .now, modelName: "GPT-4"),
                .init(id: "2", title: "Code review", lastMessage: "Here's the improved version...", updatedAt: .now.addingTimeInterval(-3600), modelName: "Claude"),
            ],
            isAuthenticated: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentChatsEntry) -> Void) {
        let entry = createEntry()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentChatsEntry>) -> Void) {
        let entry = createEntry()
        // Refresh every 15 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func createEntry() -> RecentChatsEntry {
        let shared = SharedDataService.shared
        return RecentChatsEntry(
            date: .now,
            conversations: shared.loadRecentConversations(),
            isAuthenticated: shared.isAuthenticated
        )
    }
}

// MARK: - Timeline Entry

struct RecentChatsEntry: TimelineEntry {
    let date: Date
    let conversations: [SharedDataService.RecentConversation]
    let isAuthenticated: Bool
}

// MARK: - Widget View

struct RecentChatsWidgetView: View {
    let entry: RecentChatsEntry

    @Environment(\.widgetFamily) var family

    var body: some View {
        if !entry.isAuthenticated {
            notAuthenticatedView
        } else if entry.conversations.isEmpty {
            emptyView
        } else {
            conversationsView
        }
    }

    private var notAuthenticatedView: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Sign in to Open UI")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No recent chats")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Start a conversation")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var conversationsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Recent Chats")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            .padding(.bottom, 8)

            let maxItems = family == .systemSmall ? 2 : (family == .systemMedium ? 3 : 5)

            ForEach(Array(entry.conversations.prefix(maxItems))) { conversation in
                Link(destination: URL(string: "openui://chat/\(conversation.id)")!) {
                    conversationRow(conversation)
                }

                if conversation.id != entry.conversations.prefix(maxItems).last?.id {
                    Divider()
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private func conversationRow(_ conversation: SharedDataService.RecentConversation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(conversation.title)
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text(conversation.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if family != .systemSmall {
                Text(conversation.lastMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Quick Actions Widget

/// A widget with quick action buttons for new chat, voice call, and new note.
struct QuickActionsWidget: Widget {
    let kind: String = "QuickActionsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickActionsProvider()) { entry in
            QuickActionsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Quick Actions")
        .description("Quick access to new chat, voice call, and notes.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuickActionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickActionsEntry {
        QuickActionsEntry(date: .now, isAuthenticated: true, userName: "User")
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickActionsEntry) -> Void) {
        let shared = SharedDataService.shared
        completion(QuickActionsEntry(date: .now, isAuthenticated: shared.isAuthenticated, userName: shared.userName))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickActionsEntry>) -> Void) {
        let shared = SharedDataService.shared
        let entry = QuickActionsEntry(date: .now, isAuthenticated: shared.isAuthenticated, userName: shared.userName)
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

struct QuickActionsEntry: TimelineEntry {
    let date: Date
    let isAuthenticated: Bool
    let userName: String?
}

struct QuickActionsWidgetView: View {
    let entry: QuickActionsEntry

    @Environment(\.widgetFamily) var family

    var body: some View {
        if family == .systemSmall {
            smallLayout
        } else {
            mediumLayout
        }
    }

    private var smallLayout: some View {
        VStack(spacing: 12) {
            Text("Open UI")
                .font(.caption.bold())
                .foregroundStyle(.primary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                actionButton(icon: "plus.bubble.fill", label: "Chat", url: "openui://new-chat", color: .blue)
                actionButton(icon: "phone.fill", label: "Call", url: "openui://voice-call", color: .green)
                actionButton(icon: "note.text", label: "Note", url: "openui://new-note", color: .orange)
                actionButton(icon: "arrow.uturn.forward", label: "Resume", url: "openui://continue", color: .purple)
            }
        }
    }

    private var mediumLayout: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Open UI")
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let name = entry.userName {
                    Text("Hi, \(name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                actionButton(icon: "plus.bubble.fill", label: "New Chat", url: "openui://new-chat", color: .blue)
                actionButton(icon: "phone.fill", label: "Voice Call", url: "openui://voice-call", color: .green)
                actionButton(icon: "note.text", label: "New Note", url: "openui://new-note", color: .orange)
            }
        }
    }

    private func actionButton(icon: String, label: String, url: String, color: Color) -> some View {
        Link(destination: URL(string: url)!) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: family == .systemSmall ? 20 : 24))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: - Shared Data Service (Widget-safe copy)
// The widget extension needs access to SharedDataService.
// In a real project, this would be in a shared framework target.
// For now, we reference the app group directly.

private enum WidgetSharedData {
    static let appGroupId = "group.com.openui.shared"
    static let defaults = UserDefaults(suiteName: appGroupId)
}

// MARK: - Previews

#Preview("Recent Chats - Small", as: .systemSmall) {
    RecentChatsWidget()
} timeline: {
    RecentChatsEntry(
        date: .now,
        conversations: [
            .init(id: "1", title: "Planning meeting", lastMessage: "Let me help...", updatedAt: .now, modelName: "GPT-4"),
        ],
        isAuthenticated: true
    )
}

#Preview("Quick Actions - Medium", as: .systemMedium) {
    QuickActionsWidget()
} timeline: {
    QuickActionsEntry(date: .now, isAuthenticated: true, userName: "Abhi")
}
