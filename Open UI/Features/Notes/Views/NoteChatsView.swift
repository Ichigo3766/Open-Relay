import SwiftUI

struct NoteChatsView: View {
    let session: NoteChatSession
    let initialChat: Conversation
    @State private var selected: ChatViewModel?
    @Binding var draft: ChatViewModel?
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let selected {
                ChatDetailView(viewModel: selected)
                    .onBack { self.selected = nil }
                    .onNewChat { newDraft() }
                    .onDeleteChat { self.selected = nil }
                    .id(ObjectIdentifier(selected))
            } else {
                List {
                    if let error = session.error {
                        Section {
                            Text(error)
                            Button("Retry") { Task { await session.refresh() } }
                        }
                    }
                    if let draft, draft.conversation == nil {
                        Button("Resume draft", systemImage: "square.and.pencil") { selected = draft }
                    }
                    ForEach(session.chats) { chat in
                        Button { select(chat.id) } label: {
                            Label(chat.title, systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                }
                .navigationTitle("Note chats")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Chat", systemImage: "square.and.pencil") { newDraft() }.labelStyle(.iconOnly)
                            .disabled(session.isBusy)
                    }
                }
                .overlay { if session.isBusy { ProgressView() } }
                .refreshable { await session.refresh() }
                .task { await session.refresh() }
            }
        }
        .task {
            if selected == nil { select(initialChat.id) }
        }
        .onChange(of: dependencies.apiClient.map(ObjectIdentifier.init)) { _, _ in dismiss() }
    }

    private func select(_ id: String) {
        let vm = dependencies.activeChatStore.viewModel(for: id)
        vm.noteChatSession = session
        selected = vm
    }

    private func newDraft() {
        // Keep an unfinished draft when switching between note conversations.
        if let draft, draft.conversation == nil { selected = draft; return }
        let vm = ChatViewModel()
        vm.noteChatSession = session
        vm.availableModels = dependencies.activeChatStore.cachedModels
        vm.selectedModelId = dependencies.activeChatStore.cachedDefaultModelId ?? vm.availableModels.first?.id
        draft = vm
        selected = vm
    }
}
