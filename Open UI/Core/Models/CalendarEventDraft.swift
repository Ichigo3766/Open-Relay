import Foundation

/// Only fields owned by the event editor. The server preserves omitted metadata.
struct CalendarEventDraft {
    var id: String?
    var calendarID: String
    var title: String
    var description: String
    var start: Date
    var end: Date?
    var allDay: Bool
    var location: String
    var recurrence: String
    var alertMinutes: Int

    init(event: CalendarEvent? = nil, calendarID: String, start: Date) {
        id = event?.id
        self.calendarID = event?.calendarId ?? calendarID
        title = event?.title ?? ""
        description = event?.description ?? ""
        self.start = event?.startAt ?? start
        end = event == nil ? start.addingTimeInterval(3600) : event?.endAt
        allDay = event?.allDay ?? false
        location = event?.location ?? ""
        recurrence = event?.rrule ?? ""
        alertMinutes = event?.meta?.alertMinutes ?? 10
    }

    func requestBody(calendar: Calendar = .current) throws -> [String: Any] {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        func invalid(_ message: String) -> NSError {
            NSError(domain: "CalendarEvent", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard !title.isEmpty else { throw invalid("Enter an event title.") }
        guard !calendarID.isEmpty else { throw invalid("Choose a calendar.") }
        let start = allDay ? calendar.startOfDay(for: start) : start
        let end = end.map { date in
            allDay ? calendar.date(bySettingHour: 23, minute: 59, second: 0, of: date) ?? date : date
        }
        if let end, end < start { throw invalid("The end must not be before the start.") }
        func nanoseconds(_ date: Date) throws -> Int64 {
            guard let value = Int64(exactly: (date.timeIntervalSince1970 * 1_000_000_000).rounded(.towardZero)) else {
                throw invalid("Choose a date within the supported range.")
            }
            return value
        }
        func nullable(_ text: String) -> Any {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? NSNull() : trimmed as Any
        }
        return [
            "calendar_id": calendarID, "title": title,
            "description": nullable(description), "location": nullable(location),
            "start_at": try nanoseconds(start),
            "end_at": try end.map(nanoseconds) as Any? ?? NSNull(),
            "all_day": allDay, "rrule": nullable(recurrence),
            // Native -1 disables alerts; omitting this would use the server default.
            "meta": ["alert_minutes": alertMinutes]
        ]
    }
}
