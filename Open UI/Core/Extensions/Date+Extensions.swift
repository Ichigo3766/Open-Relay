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
    
    /// Day-of-week formatter for recent dates within the past week.
    private static let _dayOfWeekFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"  // "Monday", "Tuesday", etc.
        return f
    }()
    
    /// Date separator formatter for older dates.
    private static let _dateSeparatorFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"  // "Mar 14, 2026"
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
    
    /// Time-only string for channel inline timestamps: "2:29 AM"
    var channelTime: String {
        Self._timeFormatter.string(from: self)
    }
    
    /// Date separator string for grouping channel messages by day.
    /// - Today → "Today"
    /// - Yesterday → "Yesterday"
    /// - This week → "Monday" (day name)
    /// - Older → "Mar 14, 2026"
    var channelDateSeparator: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        let daysAgo = cal.dateComponents([.day], from: self, to: .now).day ?? 0
        if daysAgo < 7 {
            return Self._dayOfWeekFormatter.string(from: self)
        }
        return Self._dateSeparatorFormatter.string(from: self)
    }
}
