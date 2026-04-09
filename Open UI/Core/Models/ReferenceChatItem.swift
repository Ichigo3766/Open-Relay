import Foundation

// MARK: - Reference Chat Item

/// Represents a chat conversation that can be attached as context to a new message.
///
/// When the user selects a chat from the "Reference Chats" picker (via the `+` menu),
/// the selected chat is shown as a chip in the composer and included in the `files`
/// array of the chat completion request — exactly matching the OpenWebUI web client.
struct ReferenceChatItem: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let updatedAt: Date
    let createdAt: Date

    /// A human-readable relative time string, e.g. "24 minutes ago".
    var relativeTime: String {
        let now = Date()
        let diff = now.timeIntervalSince(updatedAt)
        if diff < 60 {
            return "Just now"
        } else if diff < 3600 {
            let mins = Int(diff / 60)
            return "\(mins) minute\(mins == 1 ? "" : "s") ago"
        } else if diff < 86400 {
            let hours = Int(diff / 3600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        } else {
            let days = Int(diff / 86400)
            return "\(days) day\(days == 1 ? "" : "s") ago"
        }
    }

    /// The time-range bucket label used by OpenWebUI, e.g. "Today", "Yesterday", etc.
    var timeRange: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(updatedAt) {
            return "Today"
        } else if calendar.isDateInYesterday(updatedAt) {
            return "Yesterday"
        } else if let daysAgo = calendar.dateComponents([.day], from: updatedAt, to: Date()).day {
            if daysAgo <= 7 {
                return "Previous 7 days"
            } else if daysAgo <= 30 {
                return "Previous 30 days"
            }
        }
        return "Older"
    }

    /// Converts this item to the `files` array entry format expected by
    /// the `/api/chat/completions` endpoint, matching the OpenWebUI web client format.
    func toChatFileRef() -> [String: Any] {
        return [
            "type": "chat",
            "id": id,
            "name": title,
            "title": title,
            "description": relativeTime,
            "status": "processed",
            "updated_at": Int(updatedAt.timeIntervalSince1970),
            "created_at": Int(createdAt.timeIntervalSince1970)
        ]
    }
}
