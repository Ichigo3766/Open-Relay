import Foundation

@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fatalError(message) }
            count += 1
        }
        func event(_ attendees: String = #"[{"user_id":"demo-user","status":"pending"},{"user_id":"guest","status":"declined"}]"#) throws -> CalendarEvent {
            try JSONDecoder().decode(CalendarEvent.self, from: Data("""
            {"id":"series","instance_id":"occurrence","calendar_id":"crafts","title":"Paper workshop","start_at":0,"all_day":false,"attendees":\(attendees)}
            """.utf8))
        }
        let original = try event()
        check(original.attendees.count == 2, "Decode attendees")
        check(try event("null").attendees.isEmpty, "Null attendees")
        let absent = Data(#"{"id":"plain","calendar_id":"crafts","title":"Paper","start_at":0,"all_day":true}"#.utf8)
        check(try JSONDecoder().decode(CalendarEvent.self, from: absent).attendees.isEmpty, "Old server without attendees")
        check(try event(#"[{"user_id":"demo-user","status":"future-value"}]"#).attendees[0].status == "future-value", "Unknown status survives")
        let api = APIClient()
        let vm = ActionProbe(apiClient: api)
        var another = original; another.instanceId = "another-occurrence"
        var unrelated = original; unrelated = CalendarEvent(id: "other", calendarId: "crafts", title: "Other", startAt: Date(), endAt: nil)
        unrelated.attendees = original.attendees
        vm.events = [original, another, unrelated]; vm.selectedEvent = original
        try await vm.respondToEvent(original, userId: "demo-user", response: .accepted)
        check(api.network.calls.count == 1, "One request")
        check(api.network.calls[0].0 == "/api/v1/calendars/events/series/rsvp", "Use series ID, never occurrence")
        check(api.network.calls[0].1 == .post, "POST")
        check(api.network.calls[0].2 as? [String: String] == ["status": "accepted"], "Only own status, no attendee replacement")
        check(vm.events[0].attendees[0].status == "accepted" && vm.events[1].attendees[0].status == "accepted", "Update all visible occurrences")
        check(vm.events[2].attendees[0].status == "pending", "Unrelated event unchanged")
        check(vm.events[0].attendees[1].status == "declined", "Other attendee unchanged")
        check(vm.selectedEvent?.attendees[0].status == "accepted", "Selected event updated")
        check(vm.respondingEventIds.isEmpty, "No pending state after success")

        for status in CalendarRSVP.allCases {
            api.network.response = ["status": true, "rsvp": status.rawValue]
            try await vm.respondToEvent(original, userId: "demo-user", response: status)
            check(vm.events[0].attendees[0].status == status.rawValue, "All native response values")
        }
        for response: [String: Any] in [["status": false, "rsvp": "accepted"], ["status": true], ["status": true, "rsvp": "declined"], [:]] {
            api.network.response = response
            do { try await vm.respondToEvent(original, userId: "demo-user", response: .accepted); fatalError("Unexpected success") } catch {}
            check(vm.events[0].attendees[0].status == "pending", "Do not claim unconfirmed success")
        }
        api.network.fail = true
        do { try await vm.respondToEvent(original, userId: "demo-user", response: .accepted); fatalError("Expected HTTP error") } catch {}
        check(vm.events[0].attendees[0].status == "pending" && vm.respondingEventIds.isEmpty, "Failure retains response and permits retry")
        api.network.fail = false; api.network.response = ["status": true, "rsvp": "accepted"]
        api.network.suspend = true
        let first = Task { try await vm.respondToEvent(original, userId: "demo-user", response: .accepted) }
        while api.network.suspended == nil { await Task.yield() }
        let beforeDoubleTap = api.network.calls.count
        do { try await vm.respondToEvent(original, userId: "demo-user", response: .declined); fatalError("Expected busy guard") } catch {}
        check(api.network.calls.count == beforeDoubleTap, "No parallel write from double tap")
        check(vm.events[0].attendees[0].status == "pending", "Do not update during request")
        api.network.suspended?.resume(); api.network.suspended = nil
        try await first.value
        check(vm.events[0].attendees[0].status == "accepted", "Manual retry succeeds")
        let stale = Task { try await vm.respondToEvent(original, userId: "demo-user", response: .accepted) }
        while api.network.suspended == nil { await Task.yield() }
        vm.events = [original]
        api.network.conversationCacheScope = "different-account"
        api.network.suspended?.resume(); api.network.suspended = nil
        do { try await stale.value; fatalError("Expected account guard") } catch {}
        check(vm.events[0].attendees[0].status == "pending", "Ignore response after account switch")
        let beforeStale = api.network.calls.count
        do { try await vm.respondToEvent(original, userId: "demo-user", response: .accepted); fatalError("Expected stale scope guard") } catch {}
        check(api.network.calls.count == beforeStale, "Never submit from stale account scope")
        api.network.conversationCacheScope = "synthetic-account"
        let cancelled = Task { try await vm.respondToEvent(original, userId: "demo-user", response: .accepted) }
        while api.network.suspended == nil { await Task.yield() }
        cancelled.cancel(); api.network.suspended?.resume(); api.network.suspended = nil
        do { try await cancelled.value; fatalError("Expected cancellation") } catch {}
        check(vm.events[0].attendees[0].status == "pending" && vm.respondingEventIds.isEmpty, "Late cancelled response not applied")
        api.network.suspend = false
        var cancelledEvent = original; cancelledEvent.isCancelled = true
        var systemEvent = original; systemEvent = CalendarEvent(calendarId: "__scheduled_tasks__", title: "Task", startAt: Date(), endAt: nil); systemEvent.attendees = original.attendees
        for item in [cancelledEvent, systemEvent, try event("[]")] {
            let before = api.network.calls.count
            do { try await vm.respondToEvent(item, userId: "demo-user", response: .accepted); fatalError("Expected non-invitation guard") } catch {}
            check(api.network.calls.count == before, "Do not submit for cancelled/system/non-attendee")
        }
        print("\(count) calendar RSVP checks passed")
    }
}
