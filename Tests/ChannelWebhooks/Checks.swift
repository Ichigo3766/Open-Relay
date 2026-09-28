import Foundation

@main struct Checks {
    static var count = 0
    static func check(_ value: Bool, _ name: String) { precondition(value, name); count += 1 }
    @MainActor static func main() async throws {
        let data = Data(#"{"id":"paper-hook","channel_id":"crafts","name":"Paper Bot","token":"synthetic-secret","profile_image_url":"data:image/png;base64,c3ludGhldGlj"}"#.utf8)
        let hook = try JSONDecoder().decode(ChannelWebhook.self, from: data)
        check(hook.name == "Paper Bot" && hook.channelId == "crafts", "native model")
        check(hook.postingURL(serverURL: "https://example.test/relay/")?.absoluteString == "https://example.test/relay/api/v1/channels/webhooks/paper-hook/synthetic-secret", "server prefix preserved")
        check(hook.postingURL(serverURL: "https://ignored:ignored@example.test/?credential=ignored#ignored")?.absoluteString == "https://example.test/api/v1/channels/webhooks/paper-hook/synthetic-secret", "unrelated credentials removed")
        check(hook.postingURL(serverURL: "file:///tmp") == nil, "no local URL")
        let api = APIClient()
        api.network.response = Data("[".utf8) + data + Data("]".utf8)
        let listed = try await api.getChannelWebhooks(channelId: "crafts")
        check(listed.count == 1 && api.network.calls.last?.0 == "/api/v1/channels/crafts/webhooks", "list route")
        api.network.response = data
        _ = try await api.saveChannelWebhook(channelId: "crafts", webhook: hook, name: "Paper Updates")
        check(api.network.calls.last?.0 == "/api/v1/channels/crafts/webhooks/paper-hook/update", "update route")
        let body = try JSONSerialization.jsonObject(with: api.network.calls.last!.2!) as! [String: Any]
        check(body["profile_image_url"] as? String == hook.profileImageURL && body.count == 2, "rename preserves native avatar without resubmitting token")
        _ = try await api.saveChannelWebhook(channelId: "crafts", webhook: nil, name: "Paper")
        check(api.network.calls.last?.0 == "/api/v1/channels/crafts/webhooks/create", "create route")
        api.network.response = Data("true".utf8)
        try await api.deleteChannelWebhook(channelId: "crafts", webhookId: hook.id)
        check(api.network.calls.last?.0 == "/api/v1/channels/crafts/webhooks/paper-hook/delete" && api.network.calls.last?.1 == .delete, "delete route")
        api.network.response = Data("false".utf8)
        do { try await api.deleteChannelWebhook(channelId: "crafts", webhookId: hook.id); check(false, "false delete ignored") }
        catch { check(true, "false delete rejected") }
        api.network.response = Data("{}".utf8)
        do { _ = try await api.getChannelWebhooks(channelId: "crafts"); check(false, "bad list silently empty") }
        catch { check(true, "malformed list rejected") }

        let vm = ChannelWebhooksViewModel(apiClient: api, channelId: "crafts")
        api.network.response = Data("[".utf8) + data + Data("]".utf8)
        await vm.load()
        check(vm.webhooks.count == 1 && vm.errorMessage == nil, "loaded state")
        api.network.response = data
        try await vm.save(hook, name: "  Paper  ")
        check(vm.webhooks.count == 1 && !vm.isBusy, "replace single edited row")
        let trimmed = try JSONSerialization.jsonObject(with: api.network.calls.last!.2!) as! [String: Any]
        check(trimmed["name"] as? String == "Paper", "trim submitted name")
        let before = api.network.calls.count
        do { try await vm.save(nil, name: " \n"); check(false, "empty accepted") }
        catch { check(api.network.calls.count == before, "validate before request") }
        api.network.fail = true
        do { try await vm.save(nil, name: "Paper"); check(false, "save swallowed") }
        catch { check(api.network.calls.count == before + 1 && vm.webhooks.count == 1 && !vm.isBusy, "failed save keeps row and does not auto retry") }
        await vm.delete(hook)
        check(vm.webhooks.count == 1 && vm.errorMessage != nil, "failed delete retains row")
        await vm.load()
        check(vm.webhooks.isEmpty && vm.errorMessage != nil, "load error clears stale secrets")
        api.network.fail = false
        api.network.response = data
        try await vm.save(nil, name: "Paper")
        check(vm.webhooks.count == 1 && vm.errorMessage == nil, "manual recovery")
        api.network.response = Data("true".utf8)
        await vm.delete(hook)
        check(vm.webhooks.isEmpty && vm.errorMessage == nil, "successful removal")

        api.network.response = data
        api.network.suspend = true
        let first = Task { try await vm.save(nil, name: "Paper") }
        while api.network.suspended == nil { await Task.yield() }
        let activeCalls = api.network.calls.count
        do { try await vm.save(nil, name: "Other"); check(false, "parallel save accepted") }
        catch { check(api.network.calls.count == activeCalls, "duplicate tap suppressed") }
        await vm.load(); await vm.delete(hook)
        check(api.network.calls.count == activeCalls, "load/delete cannot overlap save")
        api.network.suspend = false; api.network.suspended?.resume(); api.network.suspended = nil
        try await first.value
        api.network.onRequest = { api.network.conversationCacheScope = "other-account" }
        do { try await vm.save(hook, name: "Late"); check(false, "late account write applied") }
        catch { check(vm.webhooks.isEmpty, "late response clears old account values") }
        let staleCalls = api.network.calls.count
        do { try await vm.save(nil, name: "Wrong account"); check(false, "wrong account request") }
        catch { check(api.network.calls.count == staleCalls, "stale screen cannot send to new account") }
        check(vm.postingURL(for: hook) == nil, "stale screen cannot copy secret")
        print("\(count) checks passed")
    }
}
