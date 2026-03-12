import Foundation

extension Date {
    // MARK: - Cached Formatters

    /// Shared `RelativeDateTimeFormatter` — creating a new formatter per call
    /// adds ~16ms overhead in list views with many rows.
    private static let _relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Shared `DateFormatter` for today's time display.
    private static let _timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    /// Shared `DateFormatter` for older dates.
    private static let _dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    // MARK: - Public API

    /// Returns a human-readable relative time string (e.g., "2 minutes ago").
    var relativeString: String {
        Self._relativeFormatter.localizedString(for: self, relativeTo: .now)
    }

    /// Returns a formatted string suitable for chat timestamps.
    var chatTimestamp: String {
        if Calendar.current.isDateInToday(self) {
            return Self._timeFormatter.string(from: self)
        } else if Calendar.current.isDateInYesterday(self) {
            return "Yesterday"
        } else {
            return Self._dateFormatter.string(from: self)
        }
    }
}
