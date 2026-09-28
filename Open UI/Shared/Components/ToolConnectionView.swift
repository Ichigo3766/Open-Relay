import SwiftUI

extension ToolItem {
    /// Native OAuth IDs are either `server:mcp:id`, `mcp:id`, or a bare MCP ID.
    func connectionURL(baseURL: URL) -> URL? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, !last.isEmpty,
              parts.first != "direct_server",
              var url = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        let type = parts.count == 1 ? "mcp" : (parts[0] == "server" ? parts[1] : parts[0])
        guard !type.isEmpty, parts[0] != "server" || parts.count >= 3 else { return nil }
        let segment = (type + ":" + last).addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let root = url.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = root.isEmpty ? "" : "/" + root
        url.user = nil; url.password = nil; url.fragment = nil
        url.percentEncodedPath = prefix + "/auth"
        url.queryItems = [URLQueryItem(name: "redirect", value: prefix + "/oauth/clients/" + segment + "/authorize")]
        return url.url
    }
}

/// Safari owns the login/OAuth cookies. App credentials never enter a browser URL.
struct ToolConnectionView: View {
    let tool: ToolItem
    let apiClient: APIClient
    var onRefresh: (() async -> Void)?
    let onDisable: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scope: String?
    @State private var showBrowser = false
    @State private var checking = false
    @State private var connected = false
    @State private var errorMessage: String?

    init(tool: ToolItem, apiClient: APIClient, onRefresh: (() async -> Void)?, onDisable: @escaping () -> Void) {
        self.tool = tool
        self.apiClient = apiClient
        self.onRefresh = onRefresh
        self.onDisable = onDisable
        _scope = State(initialValue: apiClient.network.conversationCacheScope)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(tool.name, systemImage: "wrench")
                    Text(connected ? "Connected. Close this screen to enable the tool or retry your message." : "Sign in with the same Open WebUI account in the browser, then authorize this tool. Return here to check the connection.")
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
                Section {
                    if let base = apiClient.network.baseURL, let url = tool.connectionURL(baseURL: base) {
                        Button("Connect in Browser", systemImage: "safari") {
                            guard scope == apiClient.network.conversationCacheScope else { return }
                            showBrowser = true
                        }
                        .sheet(isPresented: $showBrowser, onDismiss: { Task { await refresh() } }) {
                            InAppBrowserView(url: url).ignoresSafeArea()
                        }
                    } else {
                        Text("This tool does not provide a supported authorization address.").foregroundStyle(.secondary)
                    }
                    Button { Task { await refresh() } } label: {
                        if checking { ProgressView() } else { Label("Check Connection", systemImage: "arrow.clockwise") }
                    }
                    .disabled(checking)
                    Button("Use Without This Tool") {
                        guard scope == apiClient.network.conversationCacheScope else { return }
                        onDisable()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Connect Tool")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
                }
            }
        }
    }

    @MainActor private func refresh() async {
        guard !checking, scope == apiClient.network.conversationCacheScope else { return }
        checking = true
        defer { checking = false }
        do {
            let tools = try await apiClient.getTools()
            guard scope == apiClient.network.conversationCacheScope, !Task.isCancelled else { return }
            connected = tools.first(where: { $0["id"] as? String == tool.id }).map { $0["authenticated"] as? Bool ?? true } ?? false
            errorMessage = connected ? nil : "This tool is not connected. Complete authorization with the same account, then check again."
            await onRefresh?()
        } catch {
            guard scope == apiClient.network.conversationCacheScope else { return }
            connected = false
            errorMessage = "Couldn’t check the connection. Try again."
        }
    }
}
