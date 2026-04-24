import Foundation
import SwiftUI

// MARK: - View Mode

enum CalendarViewMode: String, CaseIterable {
    case day   = "Day"
    case week  = "Week"
    case month = "Month"
    case year  = "Year"

    var zoomLevel: Int {
        switch self {
        case .day:   return 0
        case .week:  return 1
        case .month: return 2
        case .year:  return 3
        }
    }

    static func from(zoomLevel: Int) -> CalendarViewMode {
        switch zoomLevel {
        case 0:  return .day
        case 1:  return .week
        case 2:  return .month
        default: return .year
        }
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class CalendarViewModel {
    private let apiClient: APIClient

    // MARK: - State

    var calendars: [OWCalendar] = []
    var events: [CalendarEvent] = []
    var isLoading = false
    var errorMessage: String?

    /// Current view mode (Day / Week / Month / Year)
    var viewMode: CalendarViewMode = .month

    /// The month currently shown in the month/year grid.
    var displayedMonth: Date = {
        let cal = Calendar.current
        let now = Date()
        return cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
    }()

    /// The date selected in the grid (defaults to today).
    var selectedDate: Date = Date()

    /// Which calendar IDs are visible (all by default).
    var visibleCalendarIds: Set<String> = []

    /// Controls the create-event sheet.
    var showCreateEvent = false

    /// Event detail sheet.
    var selectedEvent: CalendarEvent?

    /// Flag: only when set to true should NativeCalendarView programmatically
    /// navigate to selectedDate's month (used by goToToday only).
    var needsNavigateToSelected: Bool = false

    // MARK: - Init

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Loading

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await apiClient.getCalendars()
            calendars = fetched
            // All calendars visible by default
            visibleCalendarIds = Set(fetched.map { $0.id })
            await loadEventsForDisplayedMonth()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func loadEventsForDisplayedMonth() async {
        let (start, end) = monthRange(for: displayedMonth)
        do {
            let fetched = try await apiClient.getCalendarEvents(start: start, end: end)
            events = fetched
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Load events for any arbitrary date range (used by Week/Day/Year views).
    func loadEvents(from start: Date, to end: Date) async {
        do {
            let fetched = try await apiClient.getCalendarEvents(start: start, end: end)
            events = fetched
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Navigation

    func goToPreviousMonth() {
        let cal = Calendar.current
        if let prev = cal.date(byAdding: .month, value: -1, to: displayedMonth) {
            displayedMonth = prev
            Task { await loadEventsForDisplayedMonth() }
        }
    }

    func goToNextMonth() {
        let cal = Calendar.current
        if let next = cal.date(byAdding: .month, value: 1, to: displayedMonth) {
            displayedMonth = next
            Task { await loadEventsForDisplayedMonth() }
        }
    }

    func goToToday() {
        let cal = Calendar.current
        let now = Date()
        displayedMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        selectedDate = now
        needsNavigateToSelected = true
        Task { await loadEventsForDisplayedMonth() }
    }

    // MARK: - Zoom / Pinch

    /// Called when the user pinches in (zoom in = finer detail).
    func zoomIn() {
        let newLevel = max(0, viewMode.zoomLevel - 1)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            viewMode = CalendarViewMode.from(zoomLevel: newLevel)
        }
    }

    /// Called when the user pinches out (zoom out = broader view).
    func zoomOut() {
        let newLevel = min(3, viewMode.zoomLevel + 1)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            viewMode = CalendarViewMode.from(zoomLevel: newLevel)
        }
    }

    // MARK: - CRUD

    func createEvent(
        calendarId: String,
        title: String,
        description: String?,
        startAt: Date,
        endAt: Date?,
        allDay: Bool,
        location: String?,
        alertMinutes: Int?
    ) async {
        let meta: CalendarEventMeta? = alertMinutes.map { CalendarEventMeta(alertMinutes: $0) }
        let req = CalendarEventCreateRequest(
            calendarId: calendarId,
            title: title,
            description: description,
            startAt: Int64(startAt.timeIntervalSince1970 * 1_000_000_000),
            endAt: endAt.map { Int64($0.timeIntervalSince1970 * 1_000_000_000) },
            allDay: allDay,
            location: location,
            meta: meta
        )
        do {
            let created = try await apiClient.createCalendarEvent(req)
            events.append(created)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteEvent(_ event: CalendarEvent) async {
        // Use instance_id if present (recurring), else id
        let deleteId = event.instanceId ?? event.id
        do {
            try await apiClient.deleteCalendarEvent(id: deleteId)
            events.removeAll { $0.id == event.id && $0.instanceId == event.instanceId }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Computed Helpers

    /// Returns the color for a calendar by its ID.
    func color(for calendarId: String) -> Color {
        calendars.first(where: { $0.id == calendarId })?.swiftUIColor ?? .blue
    }

    /// Events on a specific day (using selectedDate or any day).
    func events(on date: Date) -> [CalendarEvent] {
        let cal = Calendar.current
        return events
            .filter { visibleCalendarIds.contains($0.calendarId) }
            .filter { cal.isDate($0.startAt, inSameDayAs: date) }
            .sorted { $0.startAt < $1.startAt }
    }

    /// Events in a week containing the given date.
    func events(inWeekOf date: Date) -> [CalendarEvent] {
        let cal = Calendar.current
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        guard let weekStart = cal.date(from: comps),
              let weekEnd = cal.date(byAdding: .day, value: 7, to: weekStart) else { return [] }
        return events
            .filter { visibleCalendarIds.contains($0.calendarId) }
            .filter { $0.startAt >= weekStart && $0.startAt < weekEnd }
            .sorted { $0.startAt < $1.startAt }
    }

    /// Events in a given month.
    func events(inMonth month: Date) -> [CalendarEvent] {
        let cal = Calendar.current
        return events
            .filter { visibleCalendarIds.contains($0.calendarId) }
            .filter {
                let ec = cal.dateComponents([.year, .month], from: $0.startAt)
                let mc = cal.dateComponents([.year, .month], from: month)
                return ec.year == mc.year && ec.month == mc.month
            }
    }

    /// Events for the selected date.
    var eventsForSelectedDate: [CalendarEvent] {
        events(on: selectedDate)
    }

    /// Event dot colors for a given day (max 3 unique calendar colors).
    func dotColors(for date: Date) -> [Color] {
        let dayEvents = events(on: date)
        var seen = Set<String>()
        var colors: [Color] = []
        for event in dayEvents {
            if seen.insert(event.calendarId).inserted {
                colors.append(color(for: event.calendarId))
                if colors.count >= 3 { break }
            }
        }
        return colors
    }

    /// Whether a date has any visible events.
    func hasEvents(on date: Date) -> Bool {
        !events(on: date).isEmpty
    }

    /// The days to display in the month grid (42 cells = 6 weeks).
    var monthGridDays: [Date] {
        let cal = Calendar.current
        guard let _ = cal.range(of: .day, in: .month, for: displayedMonth),
              let firstDay = cal.date(from: cal.dateComponents([.year, .month], from: displayedMonth))
        else { return [] }

        let weekday = cal.component(.weekday, from: firstDay) - 1

        var days: [Date] = []
        if let start = cal.date(byAdding: .day, value: -weekday, to: firstDay) {
            for i in 0..<42 {
                if let d = cal.date(byAdding: .day, value: i, to: start) {
                    days.append(d)
                }
            }
        }
        return days
    }

    /// The 7 days of the week containing selectedDate.
    var currentWeekDays: [Date] {
        let cal = Calendar.current
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: selectedDate)
        guard let weekStart = cal.date(from: comps) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
    }

    /// All 12 months for the year of displayedMonth.
    var currentYearMonths: [Date] {
        let cal = Calendar.current
        let year = cal.component(.year, from: displayedMonth)
        return (1...12).compactMap { month in
            cal.date(from: DateComponents(year: year, month: month, day: 1))
        }
    }

    var monthTitle: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        return fmt.string(from: displayedMonth)
    }

    var yearTitle: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy"
        return fmt.string(from: displayedMonth)
    }

    var defaultCalendarId: String? {
        calendars.first(where: { $0.isDefault })?.id ?? calendars.first?.id
    }

    /// Returns user-editable calendars (non-system).
    var editableCalendars: [OWCalendar] {
        calendars.filter { !$0.isSystem }
    }

    // MARK: - Private

    private func monthRange(for date: Date) -> (start: Date, end: Date) {
        let cal = Calendar.current
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: date)),
              let monthEnd = cal.date(byAdding: DateComponents(month: 1, second: -1), to: monthStart)
        else {
            return (date, date)
        }
        // Expand by one week on each side to cover grid overflow
        let start = cal.date(byAdding: .day, value: -7, to: monthStart) ?? monthStart
        let end = cal.date(byAdding: .day, value: 7, to: monthEnd) ?? monthEnd
        return (start, end)
    }
}
