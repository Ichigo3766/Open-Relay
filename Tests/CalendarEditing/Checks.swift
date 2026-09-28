import Foundation

@main struct Checks {
    static var count = 0
    static func check(_ condition: Bool, _ name: String) { precondition(condition, name); count += 1 }
    static func main() async throws {
        let start = Date(timeIntervalSince1970: 1_767_290_400)
        let event = CalendarEvent(id: "paper-series", calendarId: "craft-calendar", title: "Paper workshop",
            startAt: start, endAt: nil, rrule: "FREQ=WEEKLY;BYDAY=TU,TH;COUNT=8", meta: CalendarEventMeta(alertMinutes: -1))
        var draft = CalendarEventDraft(event: event, calendarID: "ignored", start: .distantPast)
        check(DetailProbe(event: event).reminderLabel == "None", "disabled reminder is not a negative duration")
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
        let wire = WireClient()
        wire.network.response = try JSONEncoder().encode(event)
        _ = try await wire.getCalendarEvent(id: event.id)
        check(wire.network.path == "/api/v1/calendars/events/paper-series" && wire.network.body == nil, "fetch original series")
        draft = CalendarEventDraft(event: event, calendarID: "unused", start: start)
        _ = try await wire.saveCalendarEvent(draft)
        check(wire.network.path == "/api/v1/calendars/events/paper-series/update", "native update path")
        let update = try JSONSerialization.jsonObject(with: wire.network.body!) as! [String: Any]
        check(update["rrule"] as? String == event.rrule && update["data"] == nil, "wire preserves custom rule and unsupported fields")
        draft.id = nil
        _ = try await wire.saveCalendarEvent(draft)
        check(wire.network.path == "/api/v1/calendars/events/create", "native create path")
        wire.network.fail = true
        let calls = wire.network.calls
        do { _ = try await wire.saveCalendarEvent(draft); check(false, "save failure swallowed") }
        catch { check(wire.network.calls == calls + 1, "no automatic mutation retries") }
        wire.network.fail = false
        wire.network.onRequest = { wire.network.conversationCacheScope = "other-scope" }
        do { _ = try await wire.saveCalendarEvent(draft); check(false, "stale account save") }
        catch { check(true, "reject late save from other account") }
        wire.network.conversationCacheScope = "synthetic-scope"
        do { _ = try await wire.getCalendarEvent(id: event.id); check(false, "stale account fetch") }
        catch { check(true, "reject late fetch from other account") }
        let action = ActionProbe()
        var occurrence = event
        occurrence.instanceId = "paper-series:next-week"
        occurrence.startAt = start.addingTimeInterval(7 * 86_400)
        action.selectedEvent = occurrence
        action.apiClient.result = event
        action.apiClient.refreshed = [occurrence]
        try await action.saveEvent(draft)
        check(action.selectedEvent?.startAt == occurrence.startAt, "keep selected occurrence after refreshing edited series")
        action.apiClient.failRefresh = true
        try await action.saveEvent(draft)
        check(action.errorMessage?.hasPrefix("The event was saved, but") == true, "refresh failure distinguished from failed save")
        check(action.apiClient.writes == 2 && action.events.count == 1, "saved event retained without repeat mutation")
        action.apiClient.failSave = true
        do { try await action.saveEvent(draft); check(false, "action swallowed failed save") }
        catch { check(true, "failed save propagated to editable form") }
        print("\(count) checks passed")
    }
}
