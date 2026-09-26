import SwiftUI

struct DictationQARoot: View {
    var body: some View { MainChatView() }

    static let transcript = (1...32).map {
        "Paragraph \($0). Fold a paper kite, paint a yellow sun, and add a blue ribbon to the tail."
    }.joined(separator: " ") + " END OF TRANSCRIPT."

    static func dependencies() -> AppDependencyContainer {
        let store = ServerConfigStore()
        precondition(store.servers.allSatisfy { URL(string: $0.url)?.host == "127.0.0.1" },
                     "Use a disposable synthetic-only simulator")
        let config = ServerConfig(name: "Demo", url: "http://127.0.0.1:18201", isActive: true)
        store.addServer(config)
        store.setActiveServer(id: store.server(forURL: config.url)!.id)
        UserDefaults.standard.set("", forKey: "quickPills")
        let dependencies = AppDependencyContainer()
        dependencies.authViewModel.currentUser = User(
            id: "demo", username: "Demo", email: "demo@example.test", name: "Demo")
        return dependencies
    }
}
