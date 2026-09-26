import SwiftUI

// Installed only in prepare_qa.py's disposable client copy.
struct VoiceButtonQARoot: View {
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
        let config = ServerConfig(name: "Demo", url: "http://127.0.0.1:18196", isActive: true)
        store.addServer(config)
        store.setActiveServer(id: store.server(forURL: config.url)!.id)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--qa-reset") {
            UserDefaults.standard.removeObject(forKey: "showVoiceModeButton")
        }
        UserDefaults.standard.set(arguments.contains("--qa-pills") ? "web" : "", forKey: "quickPills")
        var permissions = GroupPermissions()
        permissions.chat.call = !arguments.contains("--qa-call-denied")
        permissions.chat.stt = !arguments.contains("--qa-stt-denied")
        let dependencies = AppDependencyContainer()
        dependencies.authViewModel.currentUser = User(
            id: "demo", username: "Demo", email: "demo@example.test", name: "Demo", permissions: permissions)
        return dependencies
    }
}
