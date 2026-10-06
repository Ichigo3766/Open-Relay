import SwiftUI

extension TerminalServerSetupSection {
    func show(_ text: String, error: Bool = false) {
        message = text; failed = error
        Haptics.notify(error ? .error : .success)
    }

    func verify() async {
        guard let api else { return }
        verifying = true
        do {
            let type = try await api.verifyTerminalServer(url: url, key: key, authType: auth)
            viewModel.editTermServerType = type
            if type == "orchestrator", viewModel.editTermPolicyId.isEmpty {
                // Web: default policy id = connection id, else a slug of the name, else "default".
                let slug = viewModel.editTermName.lowercased()
                    .replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression)
                    .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                viewModel.editTermPolicyId = !viewModel.editTermId.isEmpty ? viewModel.editTermId : (slug.isEmpty ? "default" : slug)
            }
            show(type == nil ? "Server connection failed" : "Connected (\(type == "orchestrator" ? "Orchestrator" : "Terminal"))",
                 error: type == nil)
        } catch {
            viewModel.editTermServerType = nil
            show("Server connection failed", error: true)
        }
        verifying = false
    }

    func loadPolicy() async {
        guard let api, isOrchestrator, !viewModel.editTermPolicyId.isEmpty else { return }
        loadingPolicy = true
        let pid = viewModel.editTermPolicyId
        // A missing policy (404) is fine — it's created on save.
        let policy = (try? await api.terminalPolicy(url: url, key: key, authType: auth, policyId: pid)) ?? [:]
        let d = policy["data"] as? [String: Any] ?? [:]
        image = d["image"] as? String ?? ""
        cpu = d["cpu_limit"] as? String ?? "1"
        memory = d["memory_limit"] as? String ?? "1Gi"
        if let s = d["storage"] as? String { persistent = true; storageSize = s } else { persistent = false; storageSize = "5Gi" }
        idleMinutes = d["idle_timeout_minutes"] as? Int ?? 30
        envText = (d["env"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        do {
            let lc = try await api.terminalLifecycle(url: url, key: key, authType: auth, policyId: pid)
            let obj = lc["data"] ?? [String: Any]()
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                lifecycleJSON = String(decoding: data, as: UTF8.self)
            }
        } catch {
            show("Failed to load policy: \(error.localizedDescription)", error: true)
        }
        loadingPolicy = false
    }

    /// Web buildPolicyData: only non-empty fields; storage only when persistent; env when any.
    func policyData() -> [String: Any] {
        var data: [String: Any] = [:]
        if !image.isEmpty { data["image"] = image }
        if !cpu.isEmpty { data["cpu_limit"] = cpu }
        if !memory.isEmpty { data["memory_limit"] = memory }
        if persistent { data["storage"] = storageSize }
        if idleMinutes > 0 { data["idle_timeout_minutes"] = idleMinutes }
        var env: [String: String] = [:]
        for line in envText.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            let k = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
            if !k.isEmpty { env[k] = parts.count > 1 ? parts[1] : "" }
        }
        if !env.isEmpty { data["env"] = env }
        return data
    }

    func savePolicy() async {
        guard let api else { return }
        guard let lifecycle = (try? JSONSerialization.jsonObject(with: Data(lifecycleJSON.utf8))) as? [String: Any] else {
            show("Lifecycle must be a JSON object", error: true); return
        }
        savingPolicy = true
        let pid = viewModel.editTermPolicyId
        do {
            _ = try await api.terminalPolicy(url: url, key: key, authType: auth, policyId: pid, data: policyData())
            _ = try await api.terminalLifecycle(url: url, key: key, authType: auth, policyId: pid, data: lifecycle)
            show("Policy saved")
        } catch {
            show("Failed to save policy: \(error.localizedDescription)", error: true)
        }
        savingPolicy = false
    }

    func refresh() async {
        guard let api else { return }
        refreshing = true
        do {
            let n = try await api.refreshTerminals(url: url, key: key, authType: auth, policyId: viewModel.editTermPolicyId,
                                                   onlyIdle: onlyIdle, reset: resetTerminals)
            show("Refresh requested: \(n) terminal(s)")
        } catch {
            show("Failed to refresh terminals: \(error.localizedDescription)", error: true)
        }
        refreshing = false
    }
}
