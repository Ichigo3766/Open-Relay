import SwiftUI

// Used only in prepare_qa.py's disposable app copy.
struct SidebarQARoot: View {
    var body: some View { MainChatView() }

    static func dependencies() -> AppDependencyContainer {
        let store = ServerConfigStore()
        precondition(store.servers.allSatisfy { URL(string: $0.url)?.host == "127.0.0.1" },
                     "Use a disposable synthetic-only simulator")
        let config = ServerConfig(name: "Demo", url: "http://127.0.0.1:18195", isActive: true)
        store.addServer(config)
        store.setActiveServer(id: store.server(forURL: config.url)!.id)
        let arguments = ProcessInfo.processInfo.arguments
        var permissions = GroupPermissions()
        permissions.features = GroupFeaturePermissions(
            channels: !arguments.contains("--qa-no-channel-permission"),
            folders: !arguments.contains("--qa-no-folder-permission"))
        let dependencies = AppDependencyContainer()
        dependencies.authViewModel.currentUser = User(
            id: "demo", username: "Demo", email: "demo@example.test", name: "Demo",
            permissions: permissions)
        return dependencies
    }
}
