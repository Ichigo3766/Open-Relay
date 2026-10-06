import ActivityKit
import Foundation

/// Shared with the widget extension. Never includes the draft or conversation identity.
nonisolated struct DictationActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        var confirmedAt: Date
        var expiresAt: Date { confirmedAt.addingTimeInterval(90) }
    }

    var startDate: Date
}
