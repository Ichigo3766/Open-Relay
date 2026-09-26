import SwiftUI

// Test-only entry point. prepare_gallery.py installs this into a disposable copy.
// Standalone sheets are the actual production views. Container-owned toolbars
// are extracted verbatim, with their owner-state dismissal replaced by dismiss().
struct CloseButtonQARoot: View {
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--close-gallery") {
            CloseButtonGallery()
        } else {
            RootView()
        }
    }

    static func dependencies() -> AppDependencyContainer {
        if ProcessInfo.processInfo.arguments.contains("--close-gallery") {
            let store = ServerConfigStore()
            precondition(store.servers.allSatisfy { URL(string: $0.url)?.host == "127.0.0.1" },
                         "Use a disposable synthetic-only simulator")
            let config = ServerConfig(name: "Demo", url: "http://127.0.0.1:18192", isActive: true)
            store.addServer(config)
            store.setActiveServer(id: store.server(forURL: config.url)!.id)
        }
        return AppDependencyContainer()
    }
}

struct CloseButtonGallery: View {
    static let screens = ["archived", "shared", "notes", "automations", "memories",
                          "workspace", "channels", "channel-members", "dm-settings", "pinned-messages",
                          "account-picker", "admin", "edit-user", "user-chats", "integration-access",
                          "voice-settings", "voice-note", "prompt-history", "app-update", "combined-update",
                          "server-switcher", "server-sheet", "ipad-admin", "ipad-memories", "ipad-notes"]
    @Environment(AppDependencyContainer.self) private var dependencies
    @State private var index = UserDefaults.standard.integer(forKey: "close-gallery-start")
    @State private var showing = false
    @State private var showingApp = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Close-button gallery")
            Text(Self.screens[index]).accessibilityIdentifier("gallery-screen")
            Button("Open next sheet") { showing = true }
            Button("Open app sidebar") { showingApp = true }
        }
        .fullScreenCover(isPresented: $showing, onDismiss: { index = (index + 1) % Self.screens.count }) {
            CloseButtonSample(screen: Self.screens[index])
        }
        .fullScreenCover(isPresented: $showingApp) { MainChatView() }
        .task {
            dependencies.authViewModel.currentUser = User(id: "demo", username: "Demo", email: "demo@example.test", name: "Demo", role: .admin)
        }
    }
}

struct CloseButtonSample: View {
    let screen: String
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var admin = AdminViewModel()
    @State private var integrations = AdminIntegrationsViewModel()

    private var update: AppUpdateInfo {
        AppUpdateInfo(version: "9.0.0", releaseNotes: "A synthetic update used to check the close button.",
                      releaseURL: URL(string: "https://example.test/release")!)
    }

    @ViewBuilder var body: some View {
        switch screen {
        case "archived": ArchivedChatsView()
        case "shared": SharedChatsView()
        case "automations": AutomationsListView()
        case "workspace": WorkspaceView()
        case "account-picker": AccountPickerSheet(viewModel: dependencies.authViewModel, onDismiss: { dismiss() })
        case "channel-members": ChannelMembersSheet(members: [], isLoading: false)
        case "dm-settings":
            DmSettingsSheet(channel: Channel(id: "demo", userId: "demo", name: "Paper workshop"),
                            members: [], allUsers: [], currentUserId: "demo", onAddMembers: { _ in }, onLeave: {})
        case "pinned-messages": PinnedMessagesSheet(messages: [])
        case "edit-user": EditUserSheet(viewModel: admin)
        case "user-chats": UserChatsSheet(viewModel: admin, serverBaseURL: "http://127.0.0.1:18192", apiClient: dependencies.apiClient)
        case "integration-access": IntegrationAddAccessSheet(viewModel: integrations)
        case "voice-settings":
            VoiceCallSettingsSheet(sttLocale: .constant("en-US"), ttsVoiceIdentifier: .constant(""),
                                   speechService: dependencies.speechRecognitionService,
                                   ttsService: dependencies.textToSpeechService)
        case "voice-note": AudioPlayerSheet(attachment: AudioAttachment(fileName: "Paper workshop recording", duration: 12), baseURL: nil)
        case "prompt-history": PromptHistoryView(promptId: nil, versions: [], isLoading: false, currentVersionId: nil, manager: nil)
        case "app-update": UpdateAvailableSheet(update: update, onUpdate: {}, onDismiss: {})
        case "combined-update":
            CombinedUpdateSheet(appUpdate: update,
                                serverUpdate: ServerUpdateInfo(version: "1.0.0", serverName: "Demo", serverURL: "http://127.0.0.1:18192", changelogMarkdown: "Synthetic release notes."),
                                onDismiss: {})
        default:
            extractedContainer()
        }
    }

    @ViewBuilder private var containerContent: some View {
        switch screen {
        case "notes", "ipad-notes": NotesListView()
        case "memories", "ipad-memories": MemoriesView()
        case "admin", "ipad-admin": AdminConsoleView()
        case "channels": ChannelsListView()
        default:
            ScrollView {
                SavedServersView(viewModel: dependencies.authViewModel, showAddServerButton: true,
                                 onDismiss: { dismiss() })
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Switch Server")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // Generated directly from MainChatView, iPadMainChatView, and Open_UIApp.
    private func extractedContainer() -> AnyView {
        // EXTRACTED_TOOLBARS
    }
}
