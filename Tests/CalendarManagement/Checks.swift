import Foundation

@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
        func data(_ calendar: OWCalendar) throws -> Data { try JSONEncoder().encode(calendar) }
        func body(_ api: APIClient) throws -> [String: Any] { try JSONSerialization.jsonObject(with: api.network.calls.last!.2!) as! [String: Any] }
        let owner = "demo-owner"
        let crafts = OWCalendar(id: "crafts", userId: owner, name: "Crafts", color: "#3b82f6", isDefault: true, isSystem: false)
        let workshops = OWCalendar(id: "workshops", userId: owner, name: "Workshops", color: "#22c55e", isDefault: false, isSystem: false)
        let shared = OWCalendar(id: "shared", userId: "demo-guest", name: "Shared", color: "#ffffff", isDefault: true, isSystem: false)
        let system = OWCalendar(id: "__scheduled_tasks__", userId: owner, name: "Tasks", color: "#ffffff", isDefault: false, isSystem: true)
        let api = APIClient()
        api.network.response = try data(crafts)
        let decoded = try await api.saveCalendar(id: nil, name: "Crafts", color: "#3b82f6")
        check(decoded.id == "crafts", "native calendar response")
        check(api.network.calls.last!.0 == "/api/v1/calendars/create" && api.network.calls.last!.1 == .post, "create route")
        check(try body(api).count == 2 && body(api)["color"] as? String == "#3b82f6", "creation only intended fields")
        _ = try await api.saveCalendar(id: crafts.id, name: "Paper", color: nil)
        check(api.network.calls.last!.0 == "/api/v1/calendars/crafts/update", "native update")
        check(try Set(body(api).keys) == ["name"], "rename preserves color, sharing, metadata, default and data")
        _ = try await api.setDefaultCalendar(id: crafts.id)
        check(api.network.calls.last!.0 == "/api/v1/calendars/crafts/default" && api.network.calls.last!.2 == nil, "native default action")
        api.network.response = Data("{\"status\":true}".utf8)
        try await api.deleteCalendar(id: workshops.id)
        check(api.network.calls.last!.0 == "/api/v1/calendars/workshops/delete" && api.network.calls.last!.1 == .delete, "native delete action")
        for invalid in ["{}", "{\"status\":false}", "[]"] {
            api.network.response = Data(invalid.utf8)
            do { try await api.deleteCalendar(id: workshops.id); check(false, "invalid success") }
            catch { check(true, "invalid delete response rejected") }
        }
        let vm = ActionProbe(apiClient: api)
        vm.calendars = [crafts, workshops, shared, system]
        vm.visibleCalendarIds = [crafts.id, shared.id]
        var renamed = workshops; renamed.name = "Paper Workshops"
        api.network.response = try data(renamed)
        try await vm.saveCalendar(workshops, name: "  Paper Workshops \n", color: nil)
        check(vm.calendars.count == 4 && vm.calendars[1].name == renamed.name, "replace existing calendar")
        check(!vm.visibleCalendarIds.contains(workshops.id), "rename does not reveal hidden calendar")
        check(try body(api)["name"] as? String == renamed.name, "trim name")
        var fresh = workshops; fresh = OWCalendar(id: "new", userId: owner, name: "New", color: "#ffffff", isDefault: false, isSystem: false)
        api.network.response = try data(fresh)
        try await vm.saveCalendar(nil, name: "New", color: "#ffffff")
        check(vm.calendars.count == 5 && vm.visibleCalendarIds.contains("new"), "new calendar immediately available")
        let beforeInvalid = api.network.calls.count
        do { try await vm.saveCalendar(nil, name: " \n", color: nil); check(false, "blank name") } catch {}
        do { try await vm.saveCalendar(system, name: "Rename", color: nil); check(false, "system edit") } catch {}
        do { try await vm.removeCalendar(system); check(false, "system delete") } catch {}
        do { try await vm.removeCalendar(crafts); check(false, "default delete") } catch {}
        do { try await vm.makeDefaultCalendar(shared, userId: owner); check(false, "shared default") } catch {}
        check(api.network.calls.count == beforeInvalid, "protected mutations never sent")
        var chosen = workshops; chosen.isDefault = true
        api.network.response = try data(chosen)
        try await vm.makeDefaultCalendar(workshops, userId: owner)
        check(!vm.calendars[0].isDefault && vm.calendars[1].isDefault, "replace own default")
        check(vm.calendars[2].isDefault, "do not alter shared owner's default")
        api.network.fail = true
        let beforeFailure = api.network.calls.count
        do { try await vm.saveCalendar(nil, name: "Failed", color: "#ffffff"); check(false, "fail save") } catch {}
        check(api.network.calls.count == beforeFailure + 1 && vm.calendars.count == 5, "one failed attempt, state retained")
        check(!vm.isManagingCalendars, "failure clears busy flag")
        do { try await vm.removeCalendar(fresh); check(false, "fail delete") } catch {}
        check(vm.calendars.contains { $0.id == fresh.id }, "failed delete retains item")
        api.network.fail = false
        vm.events = [CalendarEvent(calendarId: fresh.id, title: "Paper", startAt: Date(), endAt: nil), CalendarEvent(calendarId: crafts.id, title: "Fold", startAt: Date(), endAt: nil)]
        vm.selectedEvent = vm.events[0]
        api.network.response = Data("{\"status\":true}".utf8)
        try await vm.removeCalendar(fresh)
        check(!vm.calendars.contains { $0.id == fresh.id } && !vm.visibleCalendarIds.contains(fresh.id), "delete removes list and visibility")
        check(vm.events.count == 1 && vm.selectedEvent == nil, "delete removes loaded events and selection")
        api.network.response = try data(fresh); api.network.suspend = true
        let pending = Task { try await vm.saveCalendar(nil, name: "New", color: "#ffffff") }
        while api.network.suspended == nil { await Task.yield() }
        check(vm.isManagingCalendars, "busy during request")
        let beforeDouble = api.network.calls.count
        do { try await vm.saveCalendar(nil, name: "Double", color: "#ffffff"); check(false, "double save") } catch {}
        do { try await vm.makeDefaultCalendar(workshops, userId: owner); check(false, "overlap default") } catch {}
        check(api.network.calls.count == beforeDouble, "one active mutation")
        api.network.suspended?.resume(); api.network.suspended = nil; api.network.suspend = false
        try await pending.value
        check(!vm.isManagingCalendars && vm.calendars.count == 5, "one insertion after completion")
        api.network.onRequest = { api.network.conversationCacheScope = "other-account" }
        do { try await vm.saveCalendar(workshops, name: "Wrong", color: nil); check(false, "late account response") } catch {}
        check(vm.calendars[1].name == renamed.name, "late response not applied")
        let beforeStale = api.network.calls.count
        do { try await vm.removeCalendar(fresh); check(false, "stale account action") } catch {}
        check(api.network.calls.count == beforeStale, "stale screen cannot mutate new account")
        print("\(count) checks passed")
    }
}
