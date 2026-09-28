import Foundation

@main struct Checks {
    static var count = 0
    static func check(_ condition: Bool, _ name: String) { precondition(condition, name); count += 1 }
    static func main() throws {
        let start = Date(timeIntervalSince1970: 1_767_290_400)
        let event = CalendarEvent(id: "paper-series", calendarId: "craft-calendar", title: "Paper workshop",
            startAt: start, endAt: nil, rrule: "FREQ=WEEKLY;BYDAY=TU,TH;COUNT=8", meta: CalendarEventMeta(alertMinutes: -1))
        var draft = CalendarEventDraft(event: event, calendarID: "ignored", start: .distantPast)
        let original = try draft.requestBody()
        check(draft.id == "paper-series", "edit native event, not generated instance")
        check(original["rrule"] as? String == event.rrule, "custom rule preserved")
        check(original["end_at"] is NSNull, "missing end preserved")
        check((original["meta"] as? [String: Int])?["alert_minutes"] == -1, "no reminder preserved")
        check(original["data"] == nil && original["attendees"] == nil && original["color"] == nil, "omit unsupported fields")
        check((original["meta"] as? [String: Any])?.count == 1, "only merge owned metadata")
        draft.title = "  Paper lanterns  "; draft.recurrence = ""; draft.description = ""; draft.location = ""
        let edited = try draft.requestBody()
        check(edited["title"] as? String == "Paper lanterns", "trim title")
        check(edited["rrule"] is NSNull && edited["description"] is NSNull && edited["location"] is NSNull, "explicit clears")
        check(edited["start_at"] as? Int64 == 1_767_290_400_000_000_000, "nanosecond native timestamp")
        draft.end = start.addingTimeInterval(-1)
        do { _ = try draft.requestBody(); check(false, "invalid end accepted") } catch { check(true, "invalid end rejected") }
        draft.end = nil; draft.title = " \n"
        do { _ = try draft.requestBody(); check(false, "empty title accepted") } catch { check(true, "empty title rejected") }
        draft.title = "Paper"; draft.calendarID = ""
        do { _ = try draft.requestBody(); check(false, "missing calendar accepted") } catch { check(true, "missing calendar rejected") }
        var fresh = CalendarEventDraft(calendarID: "craft-calendar", start: start)
        fresh.title = "Fold paper"; fresh.recurrence = "FREQ=DAILY"; fresh.alertMinutes = -1
        let created = try fresh.requestBody()
        check(fresh.id == nil && fresh.end == start.addingTimeInterval(3600), "new event defaults")
        check(created["rrule"] as? String == "FREQ=DAILY", "recurrence on create")
        fresh.allDay = true
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = try fresh.requestBody(calendar: calendar)
        check(day["start_at"] as? Int64 == Int64(calendar.startOfDay(for: start).timeIntervalSince1970 * 1_000_000_000), "all-day start")
        check(day["end_at"] as? Int64 == Int64(calendar.date(bySettingHour: 23, minute: 59, second: 0, of: start)!.timeIntervalSince1970 * 1_000_000_000), "all-day end")
        _ = try JSONSerialization.data(withJSONObject: day)
        fresh.allDay = false; fresh.start = .distantFuture; fresh.end = nil
        do { _ = try fresh.requestBody(); check(false, "unrepresentable date accepted") } catch { check(true, "unrepresentable date rejected") }
        print("\(count) checks passed")
    }
}
