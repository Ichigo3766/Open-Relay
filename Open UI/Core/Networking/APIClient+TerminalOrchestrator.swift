import Foundation

// MARK: - Terminal server orchestration (web AddTerminalServerModal)
//
// All calls go through Open WebUI (`/configs/terminal_servers/*`) so the terminal key
// stays server-side. A body without `policy_data` / `lifecycle_data` is a read.

extension APIClient {
    private func terminalBody(url: String, key: String, authType: String) -> [String: Any] {
        var u = url.trimmingCharacters(in: .whitespaces)
        while u.hasSuffix("/") { u.removeLast() }
        return ["url": u, "key": key.trimmingCharacters(in: .whitespacesAndNewlines), "auth_type": authType]
    }

    /// POST /configs/terminal_servers/verify → "orchestrator" | "terminal" (throws 400 on failure).
    func verifyTerminalServer(url: String, key: String, authType: String) async throws -> String? {
        let json = try await network.requestJSON(path: "/api/v1/configs/terminal_servers/verify", method: .post,
                                                 body: terminalBody(url: url, key: key, authType: authType))
        return json["type"] as? String
    }

    /// POST /configs/terminal_servers/policy — read (`data == nil`) or write a policy.
    func terminalPolicy(url: String, key: String, authType: String, policyId: String,
                        data: [String: Any]? = nil) async throws -> [String: Any] {
        var body = terminalBody(url: url, key: key, authType: authType)
        body["policy_id"] = policyId
        if let data { body["policy_data"] = data }
        return try await network.requestJSON(path: "/api/v1/configs/terminal_servers/policy", method: .post, body: body)
    }

    /// POST /configs/terminal_servers/lifecycle — read (`data == nil`) or write lifecycle rules.
    func terminalLifecycle(url: String, key: String, authType: String, policyId: String,
                           data: [String: Any]? = nil) async throws -> [String: Any] {
        var body = terminalBody(url: url, key: key, authType: authType)
        body["policy_id"] = policyId
        if let data { body["lifecycle_data"] = data }
        return try await network.requestJSON(path: "/api/v1/configs/terminal_servers/lifecycle", method: .post, body: body)
    }

    /// POST /configs/terminal_servers/refresh → `{refreshed: N}`.
    func refreshTerminals(url: String, key: String, authType: String, policyId: String,
                          onlyIdle: Bool, reset: Bool) async throws -> Int {
        var body = terminalBody(url: url, key: key, authType: authType)
        body["policy_id"] = policyId
        body["only_idle"] = onlyIdle
        body["reset"] = reset
        let json = try await network.requestJSON(path: "/api/v1/configs/terminal_servers/refresh", method: .post, body: body)
        return json["refreshed"] as? Int ?? 0
    }
}
