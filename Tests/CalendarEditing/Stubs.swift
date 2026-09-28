enum APIError: Error { case cancelled }
final class Network {
    enum Method { case get, post }
    var conversationCacheScope: String? = "synthetic-scope"
    var response = Data()
    var calls = 0
    var path = ""
    var body: Data?
    var fail = false
    var onRequest: (() -> Void)?
    func requestRaw(path: String, method: Method = .get, body: Data? = nil) async throws -> (Data, Int) {
        calls += 1; self.path = path; self.body = body
        onRequest?()
        if fail { throw APIError.cancelled }
        return (response, 200)
    }
}

final class EventAPI {
    var result: CalendarEvent!
    var refreshed: [CalendarEvent] = []
    var failSave = false
    var failRefresh = false
    var writes = 0
    func saveCalendarEvent(_ draft: CalendarEventDraft) async throws -> CalendarEvent {
        writes += 1
        if failSave { throw APIError.cancelled }
        return result
    }
    func refresh() throws -> [CalendarEvent] {
        if failRefresh { throw APIError.cancelled }
        return refreshed
    }
}
