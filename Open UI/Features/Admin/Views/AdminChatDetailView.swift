import SwiftUI

/// Read-only view of a user's chat. Admin can read the full history, copy it to their own
/// chats, or delete it. Opened from `UserChatsSheet`.
///
/// The transcript itself is `ReadOnlyChatTranscript`, built from the main chat's own
/// message renderers, so it looks and performs like the real chat.
struct AdminChatDetailView: View {
    @Bindable var viewModel: AdminViewModel
    let chatItem: AdminChatItem
    let serverBaseURL: String
    /// APIClient for loading authenticated images (user uploads + tool-generated images).
    let apiClient: APIClient?

    /// Called when a copy succeeds — the parent opens the copied chat.
    var onClone: ((Conversation) -> Void)?

    @Environment(\.theme) var theme
    @Environment(\.dismiss) private var dismiss
    @State var showDeleteConfirmation = false
    @State var showCloneConfirmation = false
    @State private var cloneSucceeded = false

    var body: some View {
        ZStack {
            if viewModel.isLoadingChatDetail {
                loadingSkeleton.transition(.opacity)
            } else if let error = viewModel.chatDetailError {
                errorState(error).transition(.opacity)
            } else if let conversation = viewModel.selectedChatDetail, !conversation.messages.isEmpty {
                ReadOnlyChatTranscript(
                    conversation: conversation,
                    ownerName: viewModel.viewingChatsForUser?.displayName,
                    serverBaseURL: serverBaseURL,
                    apiClient: apiClient
                )
                .transition(.opacity)
            } else {
                emptyState.transition(.opacity)
            }
        }
        .animation(MicroAnimation.fade, value: viewModel.isLoadingChatDetail)
        .background(theme.background)
        .navigationTitle(chatItem.title.isEmpty ? "Untitled Chat" : chatItem.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await viewModel.loadChatDetail(chatId: chatItem.id) }
        .overlay(alignment: .top) { cloneErrorBanner }
        .sensoryFeedback(.success, trigger: cloneSucceeded)
        .confirmationDialog("Delete Chat", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteUserChat(chatItem)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to permanently delete \"\(chatItem.title)\"? This action cannot be undone.")
        }
        .confirmationDialog("Copy to My Chats", isPresented: $showCloneConfirmation, titleVisibility: .visible) {
            Button("Copy to My Chats") { Task { await copyToMyChats() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This creates a copy of this chat in your own chat list and opens it, so you can continue the conversation.")
        }
    }

    /// Copies the chat and hands the new chat to the parent, which closes every sheet and
    /// opens it. A failure shows a banner and leaves the chat on screen.
    private func copyToMyChats() async {
        await viewModel.cloneUserChat(chatId: chatItem.id)
        if let cloned = viewModel.clonedConversation {
            cloneSucceeded.toggle()
            onClone?(cloned)
        }
    }
}
