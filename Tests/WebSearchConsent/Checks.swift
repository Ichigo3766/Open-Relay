import Foundation

@MainActor final class APIClient {
    var json = #"{"features":{"enable_web_search_confirmation":true,"web_search_confirmation_content":"Synthetic search notice."}}"#
    var fetches = 0
    var fail = false
    var suspend = false
    var gate: CheckedContinuation<Void, Never>?
    func getBackendConfig() async throws -> BackendConfig {
        fetches += 1
        if suspend { await withCheckedContinuation { gate = $0 } }
        if fail { throw NSError(domain: "Synthetic", code: 503) }
        return try JSONDecoder().decode(BackendConfig.self, from: Data(json.utf8))
    }
}

@main struct Checks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ description: String) { precondition(value, description); checks += 1 }
        let consent = WebSearchConsent(), api = APIClient()
        let first = Task { try await consent.request(using: api) }
        while consent.prompt == nil { await Task.yield() }
        let prompt = consent.prompt!
        check(prompt.message == "Synthetic search notice.", "Server notice is preserved")
        check(try await consent.request(using: api) == false, "Double tap cannot create a second operation")
        check(api.fetches == 1, "Only one config load")
        consent.resolve(id: UUID(), approved: true)
        check(consent.prompt?.id == prompt.id, "Stale alert cannot grant consent")
        consent.resolve(id: prompt.id, approved: false)
        check(try await first.value == false, "Cancel sends nothing")
        let second = Task { try await consent.request(using: api) }
        while consent.prompt == nil { await Task.yield() }
        consent.resolve(id: consent.prompt!.id, approved: true)
        check(try await second.value, "Explicit Continue authorizes")
        check(try await consent.request(using: api), "Follow-up retains consent in the same chat")
        check(api.fetches == 1, "Confirmed follow-ups do not refetch config")
        consent.reset()
        let revision = consent.revision
        consent.cancelPending()
        check(consent.revision != revision, "Navigation invalidates work that precedes policy loading")
        let third = Task { try await consent.request(using: api) }
        while consent.prompt == nil { await Task.yield() }
        consent.cancelPending()
        check(try await third.value == false && consent.prompt == nil, "Navigation cancels the pending operation")
        let cancelled = Task { try await consent.request(using: api) }
        while consent.prompt == nil { await Task.yield() }
        cancelled.cancel()
        check(try await cancelled.value == false, "Task cancellation cannot authorize")
        consent.reset()
        api.json = #"{"features":{"enable_web_search_confirmation":false}}"#
        check(try await consent.request(using: api) && consent.prompt == nil, "Disabled server policy needs no prompt")
        consent.reset()
        api.json = #"{"features":{}}"#
        check(try await consent.request(using: api), "Older servers without the flag remain supported")
        consent.reset(); api.fail = true
        do {
            _ = try await consent.request(using: api)
            preconditionFailure("Config errors must not authorize")
        } catch { checks += 1 }
        api.fail = false
        api.json = #"{"features":{"enable_web_search_confirmation":true,"web_search_confirmation_content":"  "}}"#
        let fallback = Task { try await consent.request(using: api) }
        while consent.prompt == nil { await Task.yield() }
        check(consent.prompt!.message == "Your query will be sent to the configured web search provider.", "Blank notice uses the native default")
        consent.resolve(id: consent.prompt!.id, approved: true)
        consent.reset()
        check(try await fallback.value == false, "Reset after a tap but before resumption prevents sending")
        api.suspend = true
        let stale = Task { try await consent.request(using: api) }
        while api.gate == nil { await Task.yield() }
        consent.reset(); api.gate?.resume(); api.gate = nil
        check(try await stale.value == false && consent.prompt == nil, "Late policy fetch cannot present in another account/chat")
        api.suspend = false
        let retry = Task { try await consent.request(using: api) }
        while consent.prompt == nil { await Task.yield() }
        consent.resolve(id: consent.prompt!.id, approved: true)
        check(try await retry.value, "Retry works after cancellation or policy error")
        print("\(checks) web-search consent checks passed; five entry paths and account reset checked")
    }
}
