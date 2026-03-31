import SwiftUI

// MARK: - Empty State

/// A centered empty-state view with an icon, title, description, and
/// an optional action button.
///
/// Usage:
/// ```swift
/// EmptyStateView(
///     icon: "bubble.left.and.bubble.right",
///     title: "No Conversations",
///     description: "Start a new conversation to get going.",
///     actionTitle: "New Chat"
/// ) {
///     startNewChat()
/// }
/// ```
struct EmptyStateView: View {
    let icon: String
    let title: String
    var description: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Spacing.lg) {
            iconView
            textContent
            if let actionTitle, let action {
                actionButton(title: actionTitle, action: action)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var iconView: some View {
        Image(systemName: icon)
            .scaledFont(size: 48, weight: .light)
            .foregroundStyle(theme.textTertiary.opacity(0.6))
            .frame(width: 80, height: 80)
    }

    private var textContent: some View {
        VStack(spacing: Spacing.sm) {
            Text(LocalizedStringKey(title))
                .scaledFont(size: 20, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)

            if let description {
                Text(LocalizedStringKey(description))
                    .scaledFont(size: 16)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
        }
    }

    private func actionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .scaledFont(size: 16, weight: .medium)
                .foregroundStyle(theme.buttonPrimaryText)
                .padding(.horizontal, Spacing.lg)
                .frame(height: TouchTarget.comfortable)
        }
        .buttonStyle(.borderedProminent)
        .tint(theme.brandPrimary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous))
    }
}

// MARK: - Chat Empty State

/// Specialized empty state for the chat screen with suggested prompts.
struct ChatEmptyState: View {
    var modelName: String? = nil
    var suggestions: [String] = []
    var onSuggestionTap: ((String) -> Void)? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Spacing.xl) {
            // Hero section
            VStack(spacing: Spacing.md) {
                if let modelName {
                    ModelAvatar(size: 48, label: modelName)
                } else {
                    Image(systemName: "sparkles")
                        .scaledFont(size: 36, weight: .light)
                        .foregroundStyle(theme.brandPrimary.opacity(0.7))
                }

                Text(modelName != nil ? "Chat with \(modelName!)" : "How can I help you today?")
                    .scaledFont(size: 24, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
            }

            // Suggestion chips
            if !suggestions.isEmpty {
                VStack(spacing: Spacing.sm) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        suggestionChip(suggestion)
                    }
                }
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func suggestionChip(_ text: String) -> some View {
        Button {
            onSuggestionTap?(text)
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "text.bubble")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textTertiary)

                Text(text)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)
            .background(theme.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                    .strokeBorder(theme.divider, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Error State

/// An error state view with retry functionality.
struct ErrorStateView: View {
    let message: String
    var detail: String? = nil
    var onRetry: (() -> Void)? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "exclamationmark.triangle")
                .scaledFont(size: 40, weight: .light)
                .foregroundStyle(theme.error)

            VStack(spacing: Spacing.sm) {
                Text(LocalizedStringKey(message))
                    .scaledFont(size: 20, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)

                if let detail {
                    Text(LocalizedStringKey(detail))
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }

            if let onRetry {
                Button("Try Again", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .tint(theme.brandPrimary)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Previews

#Preview("Empty States") {
    TabView {
        EmptyStateView(
            icon: "bubble.left.and.bubble.right",
            title: "No Conversations",
            description: "Start a new conversation to get going.",
            actionTitle: "New Chat",
            action: {}
        )
        .tabItem { Label("Empty", systemImage: "1.circle") }

        ChatEmptyState(
            modelName: "GPT-4",
            suggestions: [
                "Explain quantum computing in simple terms",
                "Write a SwiftUI view for a settings page",
                "Help me debug this networking code",
            ]
        )
        .tabItem { Label("Chat", systemImage: "2.circle") }

        ErrorStateView(
            message: "Something went wrong",
            detail: "Unable to load conversations. Check your connection.",
            onRetry: {}
        )
        .tabItem { Label("Error", systemImage: "3.circle") }
    }
    .themed()
}
