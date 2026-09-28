import Foundation

// MODEL

@MainActor final class Network { var conversationCacheScope: String? = "synthetic-account-a" }
@MainActor final class APIClient {
    let network = Network()
    var raw: [[String: Any]] = [["id": "server:mcp:paper", "name": "Paper Tools", "authenticated": false]]
    var failing = false
    var suspended: CheckedContinuation<Void, Never>?
    var delay = false
    var requests = 0
    func getTools() async throws -> [[String: Any]] {
        requests += 1
        if delay { await withCheckedContinuation { suspended = $0 } }
        if failing { throw NSError(domain: "Synthetic", code: 503) }
        return raw
    }
}
@MainActor final class Manager {
    let apiClient = APIClient()
    // FETCH
}
struct Attachment { let id = UUID() }
struct History { var currentId: String? = "node" }
struct Conversation { var id = "chat"; var history = History() }
@MainActor final class VM {
    var manager: Manager? = Manager()
    var selectedToolIds: Set<String> = ["server:mcp:paper"]
    var availableTools: [ToolItem] = []
    var isCheckingToolConnections = false
    var toolCheckContext = UUID()
    var conversationId: String? = "chat"
    var conversation: Conversation? = Conversation()
    var inputText = "Explain paper folding."
    var attachments: [Attachment] = []
    var selectedModelId: String? = "craft"
    var mentionedModelId: String?
    var toolConnectionRequested: ToolItem?
    var errorMessage: String?
    var refreshDefaults: (() -> Void)?
    func refreshSelectedModelMetadata() async { refreshDefaults?() }
    // GATE
}
@MainActor final class Connection {
    let tool = ToolItem(id: "server:mcp:paper", name: "Paper Tools", isAuthenticated: false)
    let apiClient = APIClient()
    var scope: String? = "synthetic-account-a"
    var checking = false
    var connected = false
    var errorMessage: String?
    var onRefresh: (() async -> Void)?
    // REFRESH
}

@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func expect(_ value: Bool, _ reason: String) {
            guard value else { fatalError(reason) }
            count += 1
        }
        let manager = Manager()
        let decoded = try await manager.fetchTools()
        expect(!decoded[0].isAuthenticated, "preserve explicit unauthenticated")
        manager.apiClient.raw = [["id": "legacy", "is_active": true], ["name": "invalid"], ["id": "ready", "authenticated": true]]
        let legacy = try await manager.fetchTools()
        expect(legacy.count == 2 && legacy.allSatisfy(\.isAuthenticated), "legacy missing flag and true remain usable")
        expect(legacy[0].isEnabled, "retain native defaults")
        for (id, client) in [("server:mcp:paper", "mcp:paper"), ("mcp:paper", "mcp:paper"), ("paper", "mcp:paper"), ("server:openapi:paper", "openapi:paper")] {
            let tool = ToolItem(id: id, name: "Demo")
            let result = URLComponents(url: tool.connectionURL(baseURL: URL(string: "https://demo.example.test/prefix/?secret=never#fragment")!)!, resolvingAgainstBaseURL: false)!
            expect(result.path == "/prefix/auth" && result.fragment == nil && result.queryItems?.count == 1, "preserve prefix, strip query/fragment")
            let redirect = result.queryItems!.first!.value!
            expect(redirect.removingPercentEncoding == "/prefix/oauth/clients/\(client)/authorize", "native OAuth client identity")
        }
        let dangerous = ToolItem(id: "mcp:a/b?token=synthetic#x", name: "Demo")
        let safe = dangerous.connectionURL(baseURL: URL(string: "https://user:password@demo.example.test")!)!
        expect(safe.user == nil && safe.password == nil && safe.fragment == nil, "never browser credentials")
        let redirect = URLComponents(url: safe, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
        expect(redirect.contains("%2F") && redirect.contains("%3F") && redirect.contains("%23"), "encode identifier, not query/path injection")
        for id in ["", "server:mcp", "server::x", "mcp:", "direct_server:0"] {
            expect(ToolItem(id: id, name: "Demo").connectionURL(baseURL: URL(string: "https://demo.example.test")!) == nil, "reject invalid/direct identity")
        }
        expect(ToolItem(id: "a", name: "Demo").connectionURL(baseURL: URL(string: "file:///tmp/demo")!) == nil, "reject nonweb scheme")

        let vm = VM()
        expect(!(await vm.checkToolConnections()), "unauthenticated blocks")
        expect(vm.toolConnectionRequested?.id == "server:mcp:paper" && vm.inputText == "Explain paper folding.", "connection request preserves draft")
        expect(!vm.isCheckingToolConnections, "gate resets")
        vm.manager!.apiClient.raw[0]["authenticated"] = true
        expect(await vm.checkToolConnections(), "connected proceeds")
        vm.manager!.apiClient.failing = true
        expect(!(await vm.checkToolConnections()) && vm.errorMessage != nil, "network failure blocks, no stale success")
        vm.manager!.apiClient.failing = false
        vm.manager!.apiClient.raw = []
        expect(!(await vm.checkToolConnections()), "removed tool blocks")
        vm.selectedToolIds = []
        let requests = vm.manager!.apiClient.requests
        expect(await vm.checkToolConnections(), "no tools no gate")
        expect(vm.manager!.apiClient.requests == requests, "no tools no request")
        vm.selectedToolIds = ["filter"]
        vm.availableTools = [ToolItem(id: "filter", name: "Filter", isFunctionTool: true)]
        expect(await vm.checkToolConnections(), "filter is not OAuth integration")
        expect(vm.manager!.apiClient.requests == requests, "filter requires no tools request")
        let assigned = VM(); assigned.selectedToolIds = []
        assigned.refreshDefaults = { assigned.selectedToolIds = ["server:mcp:paper"] }
        expect(!(await assigned.checkToolConnections()) && assigned.toolConnectionRequested != nil, "new model defaults are checked before sending")

        let changes: [(VM) -> Void] = [
            { $0.manager!.apiClient.network.conversationCacheScope = "synthetic-account-b" },
            { $0.conversationId = "another-chat" }, { $0.inputText += " changed" },
            { $0.selectedModelId = "other" }, { $0.mentionedModelId = "other" },
            { $0.selectedToolIds = [] }, { $0.attachments = [Attachment()] },
            { $0.conversation?.history.currentId = "another-branch" }, { $0.toolCheckContext = UUID() }
        ]
        for change in changes {
            let vm = VM(); vm.manager!.apiClient.delay = true
            let task = Task { await vm.checkToolConnections() }
            while vm.manager!.apiClient.suspended == nil { await Task.yield() }
            expect(!(await vm.checkToolConnections()) && vm.manager!.apiClient.requests == 1, "double tap single flight")
            change(vm)
            vm.manager!.apiClient.suspended!.resume()
            expect(!(await task.value) && vm.toolConnectionRequested == nil && vm.errorMessage == nil, "late result cannot affect changed context")
        }
        let cancelled = VM(); cancelled.manager!.apiClient.delay = true
        let task = Task { await cancelled.checkToolConnections() }
        while cancelled.manager!.apiClient.suspended == nil { await Task.yield() }
        task.cancel(); cancelled.manager!.apiClient.suspended!.resume()
        expect(!(await task.value) && cancelled.toolConnectionRequested == nil, "cancelled response ignored")

        let connection = Connection()
        var refreshes = 0
        connection.onRefresh = { refreshes += 1 }
        await connection.refresh()
        expect(!connection.connected && connection.errorMessage != nil, "browser dismissal is not success")
        connection.apiClient.raw[0]["authenticated"] = true
        await connection.refresh()
        expect(connection.connected && connection.errorMessage == nil && refreshes == 2, "server-verified connection refreshes picker")
        connection.apiClient.failing = true
        await connection.refresh()
        expect(!connection.connected && connection.errorMessage != nil && !connection.checking, "refresh error resets status")
        connection.apiClient.failing = false; connection.apiClient.delay = true
        let refresh = Task { await connection.refresh() }
        while connection.apiClient.suspended == nil { await Task.yield() }
        let before = connection.apiClient.requests
        await connection.refresh()
        expect(connection.apiClient.requests == before, "refresh single flight")
        connection.apiClient.network.conversationCacheScope = "synthetic-account-b"
        connection.apiClient.suspended!.resume(); await refresh.value
        expect(!connection.connected && refreshes == 2, "late refresh cannot connect different account")
        await connection.refresh()
        expect(connection.apiClient.requests == before, "stale screen does not query new account")
        print("\(count) checks passed")
    }
}
