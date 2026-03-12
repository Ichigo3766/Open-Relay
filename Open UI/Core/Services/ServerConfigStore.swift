import Foundation

/// Manages persistence and retrieval of server configurations.
@Observable
final class ServerConfigStore {
    private(set) var servers: [ServerConfig] = []

    private static let storageKey = "openui.server_configs"

    init() {
        loadServers()
    }

    /// The currently active server configuration.
    var activeServer: ServerConfig? {
        servers.first(where: \.isActive)
    }

    /// Adds a new server configuration and persists it.
    func addServer(_ config: ServerConfig) {
        var newConfig = config
        // If this is the first server, make it active
        if servers.isEmpty {
            newConfig.isActive = true
        }
        servers.append(newConfig)
        saveServers()
    }

    /// Updates an existing server configuration.
    func updateServer(_ config: ServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == config.id }) else { return }
        servers[index] = config
        saveServers()
    }

    /// Removes a server configuration by ID.
    func removeServer(id: String) {
        servers.removeAll(where: { $0.id == id })
        saveServers()
    }

    /// Removes all server configurations.
    func removeAllServers() {
        servers.removeAll()
        saveServers()
    }

    /// Sets a server as the active connection.
    func setActiveServer(id: String) {
        for index in servers.indices {
            servers[index].isActive = (servers[index].id == id)
        }
        saveServers()
    }

    // MARK: - Persistence

    private func saveServers() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func loadServers() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([ServerConfig].self, from: data)
        else { return }
        servers = decoded
    }
}
