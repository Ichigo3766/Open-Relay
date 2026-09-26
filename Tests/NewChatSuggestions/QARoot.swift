import SwiftUI

// Installed only in a disposable QA copy. Both screens are production views.
struct SuggestionsQARoot: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @State private var showingSettings = ProcessInfo.processInfo.arguments.contains("--qa-settings")

    var body: some View {
        MainChatView()
            .sheet(isPresented: $showingSettings) {
                SettingsView(viewModel: dependencies.authViewModel,
                             appearanceManager: dependencies.appearanceManager)
            }
    }

    static func dependencies() -> AppDependencyContainer {
        let store = ServerConfigStore()
        precondition(store.servers.allSatisfy { URL(string: $0.url)?.host == "127.0.0.1" },
                     "Use a disposable synthetic-only simulator")
        let config = ServerConfig(name: "Demo", url: "http://127.0.0.1:18194", isActive: true)
        store.addServer(config)
        store.setActiveServer(id: store.server(forURL: config.url)!.id)
        if ProcessInfo.processInfo.arguments.contains("--qa-reset") {
            UserDefaults.standard.removeObject(forKey: "showNewChatSuggestions")
        }
        let dependencies = AppDependencyContainer()
        dependencies.authViewModel.currentUser = User(id: "demo", username: "Demo",
                                                     email: "demo@example.test", name: "Demo", role: .admin)
        return dependencies
    }
}
