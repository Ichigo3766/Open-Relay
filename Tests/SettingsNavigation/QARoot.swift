import SwiftUI

// Installed only in the disposable QA copy. SettingsView itself is unmodified.
struct SettingsQARoot: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @State private var showing = false

    var body: some View {
        Button("Open Settings") { showing = true }
            .sheet(isPresented: $showing) {
                SettingsView(viewModel: dependencies.authViewModel,
                             appearanceManager: dependencies.appearanceManager)
            }
    }

    static func dependencies() -> AppDependencyContainer {
        let store = ServerConfigStore()
        precondition(store.servers.allSatisfy { URL(string: $0.url)?.host == "127.0.0.1" },
                     "Use a disposable synthetic-only simulator")
        let config = ServerConfig(name: "Demo", url: "http://127.0.0.1:18193", isActive: true)
        store.addServer(config)
        store.setActiveServer(id: store.server(forURL: config.url)!.id)
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--qa-language"), index + 1 < args.count {
            UserDefaults.standard.set([args[index + 1]], forKey: "AppleLanguages")
        } else if !args.contains("--qa-preserve-language") {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        let dependencies = AppDependencyContainer()
        dependencies.authViewModel.currentUser = User(id: "demo", username: "Demo",
                                                     email: "demo@example.test", name: "Demo", role: .admin)
        return dependencies
    }
}
