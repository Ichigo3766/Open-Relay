import SwiftUI

// MARK: - Toolbar, Banner and States

extension AdminChatDetailView {

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showCloneConfirmation = true
            } label: {
                if viewModel.isCloning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Copy to My Chats", systemImage: "square.and.arrow.down.on.square")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(theme.brandPrimary)
                }
            }
            .disabled(viewModel.isCloning || viewModel.isLoadingChatDetail || viewModel.selectedChatDetail == nil)

            Button {
                showDeleteConfirmation = true
            } label: {
                if viewModel.isDeletingChat {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(theme.error)
                }
            }
            .disabled(viewModel.isDeletingChat || viewModel.isLoadingChatDetail)
        }
    }

    /// Shown when a copy fails. The chat stays visible; the banner clears itself.
    @ViewBuilder
    var cloneErrorBanner: some View {
        if let message = viewModel.cloneError {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill").scaledFont(size: 12)
                Text(message).scaledFont(size: 12, weight: .medium).lineLimit(2)
            }
            .foregroundStyle(theme.textInverse)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(theme.error.opacity(0.92), in: Capsule())
            .padding(.top, Spacing.md)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task {
                try? await Task.sleep(for: .seconds(4))
                withAnimation(MicroAnimation.gentle) { viewModel.cloneError = nil }
            }
        }
    }

    // MARK: States

    /// Placeholder rows while the chat loads, instead of a bare spinner page.
    var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            ForEach(0..<4, id: \.self) { index in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.surfaceContainer)
                        .frame(width: index.isMultiple(of: 2) ? 180 : 120, height: 14)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.surfaceContainer.opacity(0.7))
                        .frame(height: 12)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.surfaceContainer.opacity(0.5))
                        .frame(width: 220, height: 12)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.xl)
        .redacted(reason: .placeholder)
        .accessibilityLabel("Loading conversation")
    }

    func errorState(_ message: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .scaledFont(size: 40)
                .foregroundStyle(theme.error)
            Text(message)
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await viewModel.loadChatDetail(chatId: chatItem.id) }
            }
            .scaledFont(size: 16)
            .fontWeight(.semibold)
            .foregroundStyle(theme.brandPrimary)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .scaledFont(size: 40)
                .foregroundStyle(theme.textTertiary)
            Text("No messages in this chat")
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
