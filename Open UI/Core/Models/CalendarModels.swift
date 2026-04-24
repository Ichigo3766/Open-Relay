import Foundation
import SwiftUI

// MARK: - Calendar

/// A calendar container (e.g. "Personal", "Scheduled Tasks").
struct OWCalendar: Codable, Identifiable, Sendable {
    let id: String
    let userId: String
    var name: String
    var color: String
    var isDefault: Bool
    var isSystem: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name
        case color
        case isDefault = "is_default"
        case isSystem = "is_system"
    }

    /// SwiftUI `Color` from the hex string stored in `color`.
    var swiftUIColor: Color {
        Color(hex: color) ?? .blue
    }
}

// MARK: - CalendarEvent

/// A single event (or recurring event instance) on a calendar.
struct CalendarEvent: Codable, Identifiable, Sendable {
    let id: String
    let calendarId: String
    let userId: String?
    var title: String
    var description: String?
    /// Nanosecond Unix epoch for event start.
    var startAt: Date
    /// Nanosecond Unix epoch for event end (may be nil for instant events).
    var endAt: Date?
    var allDay: Bool
    var rrule: String?
    var color: String?
    var location: String?
    var isCancelled: Bool
    /// Event metadata (e.g. alert_minutes, automation_id, run_id, status).
    var meta: CalendarEventMeta?
    /// Instance ID for recurring event instances.
    var instanceId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case calendarId = "calendar_id"
        case userId = "user_id"
        case title
        case description
        case startAt = "start_at"
        case endAt = "end_at"
        case allDay = "all_day"
        case rrule
        case color
        case location
        case isCancelled = "is_cancelled"
        case meta
        case instanceId = "instance_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self, forKey: .id)
        calendarId  = try c.decode(String.self, forKey: .calendarId)
        userId      = try c.decodeIfPresent(String.self, forKey: .userId)
        title       = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        allDay      = try c.decode(Bool.self, forKey: .allDay)
        rrule       = try c.decodeIfPresent(String.self, forKey: .rrule)
        color       = try c.decodeIfPresent(String.self, forKey: .color)
        location    = try c.decodeIfPresent(String.self, forKey: .location)
        isCancelled = (try? c.decode(Bool.self, forKey: .isCancelled)) ?? false
        meta        = try c.decodeIfPresent(CalendarEventMeta.self, forKey: .meta)
        instanceId  = try c.decodeIfPresent(String.self, forKey: .instanceId)
        startAt     = Self.decodeNanoDate(c, key: .startAt) ?? Date()
        endAt       = Self.decodeNanoDate(c, key: .endAt)
    }

    // Memberwise init for creating new events
    init(id: String = UUID().uuidString,
         calendarId: String,
         userId: String? = nil,
         title: String,
         description: String? = nil,
         startAt: Date,
         endAt: Date?,
         allDay: Bool = false,
         rrule: String? = nil,
         color: String? = nil,
         location: String? = nil,
         isCancelled: Bool = false,
         meta: CalendarEventMeta? = nil,
         instanceId: String? = nil) {
        self.id = id
        self.calendarId = calendarId
        self.userId = userId
        self.title = title
        self.description = description
        self.startAt = startAt
        self.endAt = endAt
        self.allDay = allDay
        self.rrule = rrule
        self.color = color
        self.location = location
        self.isCancelled = isCancelled
        self.meta = meta
        self.instanceId = instanceId
    }

    private static func decodeNanoDate(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Date? {
        if let ns = try? c.decodeIfPresent(Int64.self, forKey: key) {
            return Date(timeIntervalSince1970: Double(ns) / 1_000_000_000.0)
        }
        if let s = try? c.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: s / 1_000_000_000.0)
        }
        return nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(calendarId, forKey: .calendarId)
        try c.encodeIfPresent(userId, forKey: .userId)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(Int64(startAt.timeIntervalSince1970 * 1_000_000_000), forKey: .startAt)
        if let endAt { try c.encode(Int64(endAt.timeIntervalSince1970 * 1_000_000_000), forKey: .endAt) }
        try c.encode(allDay, forKey: .allDay)
        try c.encodeIfPresent(rrule, forKey: .rrule)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encode(isCancelled, forKey: .isCancelled)
        try c.encodeIfPresent(meta, forKey: .meta)
        try c.encodeIfPresent(instanceId, forKey: .instanceId)
    }

    /// SwiftUI color for this event (falls back to calendar color which is resolved externally).
    var swiftUIColor: Color? {
        guard let hex = color else { return nil }
        return Color(hex: hex)
    }

    /// True if this is a scheduled-task automation event.
    var isAutomationEvent: Bool {
        calendarId == "__scheduled_tasks__"
    }

    /// True if this is a completed automation run record.
    var isRunEvent: Bool {
        id.hasPrefix("run_")
    }

    /// Duration in seconds (nil if endAt is nil or same as startAt).
    var duration: TimeInterval? {
        guard let end = endAt, end > startAt else { return nil }
        return end.timeIntervalSince(startAt)
    }
}

// MARK: - CalendarEventMeta

struct CalendarEventMeta: Codable, Sendable {
    var alertMinutes: Int?
    var automationId: String?
    var runId: String?
    var chatId: String?
    var status: String?

    enum CodingKeys: String, CodingKey {
        case alertMinutes = "alert_minutes"
        case automationId = "automation_id"
        case runId = "run_id"
        case chatId = "chat_id"
        case status
    }
}

// MARK: - CalendarEventCreateRequest

struct CalendarEventCreateRequest: Encodable {
    let calendarId: String
    let title: String
    let description: String?
    let startAt: Int64      // nanoseconds
    let endAt: Int64?
    let allDay: Bool
    let location: String?
    let meta: CalendarEventMeta?

    enum CodingKeys: String, CodingKey {
        case calendarId = "calendar_id"
        case title
        case description
        case startAt = "start_at"
        case endAt = "end_at"
        case allDay = "all_day"
        case location
        case meta
    }
}

