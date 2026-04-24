import Foundation

// MARK: - Automation Data

/// The `data` payload embedded in an Automation.
struct AutomationData: Codable, Sendable {
    var prompt: String
    var modelId: String
    var rrule: String
    var terminal: String?

    enum CodingKeys: String, CodingKey {
        case prompt
        case modelId = "model_id"
        case rrule
        case terminal
    }
}

// MARK: - Automation Run

/// A single execution record for an automation.
struct AutomationRun: Codable, Identifiable, Sendable {
    let id: String
    let automationId: String
    let chatId: String?      // may be null if run hasn't created a chat yet
    let status: String       // "success" | "error"
    let error: String?
    /// nanosecond Unix timestamp → converted to Date
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case automationId = "automation_id"
        case chatId = "chat_id"
        case status
        case error
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self, forKey: .id)
        automationId = try c.decode(String.self, forKey: .automationId)
        chatId      = try c.decodeIfPresent(String.self, forKey: .chatId)
        status      = try c.decode(String.self, forKey: .status)
        error       = try c.decodeIfPresent(String.self, forKey: .error)
        // The server sends nanosecond timestamps as integers
        if let ns = try? c.decode(Int64.self, forKey: .createdAt) {
            createdAt = Date(timeIntervalSince1970: Double(ns) / 1_000_000_000.0)
        } else if let s = try? c.decode(Double.self, forKey: .createdAt) {
            createdAt = Date(timeIntervalSince1970: s / 1_000_000_000.0)
        } else {
            createdAt = Date()
        }
    }

    var isSuccess: Bool { status == "success" }
}

// MARK: - Automation

/// Represents a scheduled automation.
struct Automation: Codable, Identifiable, Sendable {
    let id: String
    let userId: String
    var name: String
    var data: AutomationData
    // meta is omitted — not needed by the app
    var isActive: Bool
    let lastRunAt: Date?
    let nextRunAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let lastRun: AutomationRun?
    let nextRuns: [Date]?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name
        case data
        case isActive = "is_active"
        case lastRunAt = "last_run_at"
        case nextRunAt = "next_run_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastRun = "last_run"
        case nextRuns = "next_runs"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(String.self, forKey: .id)
        userId   = try c.decode(String.self, forKey: .userId)
        name     = try c.decode(String.self, forKey: .name)
        data     = try c.decode(AutomationData.self, forKey: .data)
        isActive = try c.decode(Bool.self, forKey: .isActive)
        lastRun  = try c.decodeIfPresent(AutomationRun.self, forKey: .lastRun)

        lastRunAt  = Self.decodeNanoDate(c, key: .lastRunAt)
        nextRunAt  = Self.decodeNanoDate(c, key: .nextRunAt)
        createdAt  = Self.decodeNanoDate(c, key: .createdAt) ?? Date()
        updatedAt  = Self.decodeNanoDate(c, key: .updatedAt) ?? Date()

        if let nsList = try? c.decode([Int64].self, forKey: .nextRuns) {
            nextRuns = nsList.map { Date(timeIntervalSince1970: Double($0) / 1_000_000_000.0) }
        } else {
            nextRuns = nil
        }
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

    // Default memberwise init for creating from scratch
    init(id: String = UUID().uuidString, userId: String = "", name: String,
         data: AutomationData, isActive: Bool = true,
         lastRunAt: Date? = nil, nextRunAt: Date? = nil,
         createdAt: Date = .now, updatedAt: Date = .now,
         lastRun: AutomationRun? = nil, nextRuns: [Date]? = nil) {
        self.id = id; self.userId = userId; self.name = name
        self.data = data; self.isActive = isActive
        self.lastRunAt = lastRunAt; self.nextRunAt = nextRunAt
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.lastRun = lastRun; self.nextRuns = nextRuns
    }

    /// Human-readable schedule description parsed from the RRULE.
    var scheduleDescription: String {
        AutomationSchedule.fromRRule(data.rrule).displayString(rrule: data.rrule)
    }
}

// MARK: - Paginated Response

struct AutomationListResponse: Codable {
    let items: [Automation]
    let total: Int
}

// AnyCodable is defined in AdminUser.swift — no duplicate needed here.

// MARK: - AutomationSchedule

enum AutomationSchedule: String, CaseIterable, Sendable {
    case once    = "Once"
    case hourly  = "Hourly"
    case daily   = "Daily"
    case weekly  = "Weekly"
    case monthly = "Monthly"
    case custom  = "Custom"

    var systemImage: String {
        switch self {
        case .once:    return "1.circle"
        case .hourly:  return "clock"
        case .daily:   return "sun.max"
        case .weekly:  return "calendar.badge.clock"
        case .monthly: return "calendar"
        case .custom:  return "slider.horizontal.3"
        }
    }

    /// Parse an RRULE string → schedule type.
    static func fromRRule(_ rrule: String) -> AutomationSchedule {
        let upper = rrule.uppercased()
        // DTSTART-prefixed "once" (web UI format) OR COUNT=1 in the RRULE part
        if upper.contains("COUNT=1") { return .once }
        if upper.contains("FREQ=HOURLY") { return .hourly }
        if upper.contains("FREQ=DAILY") { return .daily }
        if upper.contains("FREQ=WEEKLY") { return .weekly }
        if upper.contains("FREQ=MONTHLY") { return .monthly }
        return .custom
    }

    /// Build an RRULE string from this schedule type + time.
    /// - Parameter date: Required for `.once` to embed the full DTSTART timestamp.
    func toRRule(hour: Int = 9, minute: Int = 0, weekdays: Set<Int> = [1], monthDay: Int = 1, date: Date? = nil) -> String {
        switch self {
        case .once:
            // Use the provided date (or now) to create a proper DTSTART + RRULE pair
            let targetDate = date ?? Date()
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd'T'HHmmss"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            let dtstart = fmt.string(from: targetDate)
            return "DTSTART:\(dtstart)\nRRULE:FREQ=DAILY;COUNT=1"
        case .hourly:
            return "RRULE:FREQ=HOURLY;BYMINUTE=\(minute)"
        case .daily:
            return "RRULE:FREQ=DAILY;BYHOUR=\(hour);BYMINUTE=\(minute)"
        case .weekly:
            let dayNames = ["SU","MO","TU","WE","TH","FR","SA"]
            let sorted = weekdays.sorted()
            let byDay = sorted.compactMap { i -> String? in
                guard i >= 0 && i < dayNames.count else { return nil }
                return dayNames[i]
            }.joined(separator: ",")
            let days = byDay.isEmpty ? "MO" : byDay
            return "RRULE:FREQ=WEEKLY;BYDAY=\(days);BYHOUR=\(hour);BYMINUTE=\(minute)"
        case .monthly:
            return "RRULE:FREQ=MONTHLY;BYMONTHDAY=\(monthDay);BYHOUR=\(hour);BYMINUTE=\(minute)"
        case .custom:
            return ""
        }
    }

    /// Human-readable string from a full RRULE, e.g. "Daily at 12:03 AM"
    func displayString(rrule: String) -> String {
        let hour   = Self.extractHour(rrule)
        let minute = Self.extractMinute(rrule)
        // For "once", try to show the full date+time from DTSTART
        if case .once = self {
            if let dt = Self.extractDTSTARTDate(rrule) {
                let fmt = DateFormatter()
                fmt.dateFormat = "MMM d, yyyy 'at' h:mm a"
                return "Once on \(fmt.string(from: dt))"
            }
            // Fallback: BYHOUR/BYMINUTE style (old format)
            let cal = Calendar.current
            if let d = cal.date(from: DateComponents(hour: hour, minute: minute)) {
                let fmt = DateFormatter()
                fmt.dateFormat = "h:mm a"
                return "Once at \(fmt.string(from: d))"
            }
            return "Once"
        }
        let timeStr: String = {
            let date = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
            let fmt = DateFormatter()
            fmt.dateFormat = "h:mm a"
            return " at \(fmt.string(from: date))"
        }()
        switch self {
        case .once: return "Once" // handled above
        case .hourly:
            return "Hourly at :\(String(format: "%02d", minute))"
        case .daily:   return "Daily\(timeStr)"
        case .weekly:
            let dayStr: String = {
                guard let match = rrule.uppercased().range(of: "BYDAY=([A-Z,]+)", options: .regularExpression),
                      let capture = rrule.uppercased()[match].components(separatedBy: "=").last else { return "" }
                let dayMap = ["MO":"Mon","TU":"Tue","WE":"Wed","TH":"Thu","FR":"Fri","SA":"Sat","SU":"Sun"]
                let days = capture.components(separatedBy: ",").compactMap { dayMap[$0] }
                return days.isEmpty ? "" : " on \(days.joined(separator: ", "))"
            }()
            return "Weekly\(dayStr)\(timeStr)"
        case .monthly:
            if let d = Self.extractInt(rrule, key: "BYMONTHDAY") {
                return "Monthly on day \(d)\(timeStr)"
            }
            return "Monthly\(timeStr)"
        case .custom:
            return rrule.isEmpty ? "Custom" : rrule
        }
    }

    private static func extractInt(_ rrule: String, key: String) -> Int? {
        // e.g. "BYHOUR=9" → 9
        guard let range = rrule.uppercased().range(of: "\(key)=([0-9]+)", options: .regularExpression),
              let numStr = rrule.uppercased()[range].components(separatedBy: "=").last,
              let val = Int(numStr) else { return nil }
        return val
    }
}

// MARK: - RRULE parse helpers (time extraction)

extension AutomationSchedule {
    /// Parses a DTSTART value from strings like:
    ///   "DTSTART:20260424T105100\nRRULE:..."
    /// Returns nil if no DTSTART is present.
    static func extractDTSTARTDate(_ rrule: String) -> Date? {
        // Match DTSTART:yyyyMMddTHHmmss (with optional Z)
        let pattern = "DTSTART:([0-9]{8}T[0-9]{6}Z?)"
        guard let range = rrule.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
              let valueRange = rrule[range].range(of: ":", options: .literal) else { return nil }
        let dtString = String(rrule[range][rrule[range].index(after: valueRange.lowerBound)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Z", with: "")
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        // DTSTART without timezone is local time
        fmt.timeZone = TimeZone.current
        return fmt.date(from: dtString)
    }

    static func extractHour(_ rrule: String) -> Int {
        // Try BYHOUR first, then fall back to DTSTART
        if let h = extractInt(rrule, key: "BYHOUR") { return h }
        if let dt = extractDTSTARTDate(rrule) {
            return Calendar.current.component(.hour, from: dt)
        }
        return 9
    }
    static func extractMinute(_ rrule: String) -> Int {
        // Try BYMINUTE first, then fall back to DTSTART
        if let m = extractInt(rrule, key: "BYMINUTE") { return m }
        if let dt = extractDTSTARTDate(rrule) {
            return Calendar.current.component(.minute, from: dt)
        }
        return 0
    }
    /// Returns the set of selected weekday indices (0=Su,1=Mo,...,6=Sa) from a BYDAY clause.
    static func extractWeekdays(_ rrule: String) -> Set<Int> {
        let dayMap = ["SU": 0, "MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6]
        guard let range = rrule.uppercased().range(of: "BYDAY=([A-Z,]+)", options: .regularExpression),
              let capture = rrule.uppercased()[range].components(separatedBy: "=").last else { return [1] }
        let days = capture.components(separatedBy: ",")
        let indices = days.compactMap { dayMap[String($0.prefix(2))] }
        return indices.isEmpty ? [1] : Set(indices)
    }
    static func extractMonthDay(_ rrule: String) -> Int {
        extractInt(rrule, key: "BYMONTHDAY") ?? 1
    }
}
