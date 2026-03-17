import SwiftUI

// MARK: - Prompt Picker View

/// A searchable overlay that displays the user's prompt library, triggered by `/` in the chat input.
///
/// Follows the same UX pattern as `KnowledgePickerView` and `ModelPickerView`:
/// - Floats above the input field
/// - Filters in real-time as the user types after `/`
/// - Supports keyboard navigation (arrow keys, Enter, Escape)
/// - Dismisses on selection or Escape
struct PromptPickerView: View {
    let query: String
    let prompts: [PromptItem]
    let isLoading: Bool
    let onSelect: (PromptItem) -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @State private var highlightedIndex: Int = 0

    /// Prompts filtered by the current query, matching on command and name.
    /// Only shows active prompts (is_active == true).
    private var filteredPrompts: [PromptItem] {
        let active = prompts.filter(\.isActive)
        guard !query.isEmpty else { return active }
        let lowered = query.lowercased()
        return active.filter { prompt in
            prompt.command.lowercased().contains(lowered) ||
            prompt.name.lowercased().contains(lowered)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "text.book.closed")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                Text("Prompts")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if !query.isEmpty {
                    Text("Filtering: /\(query)")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)

            Divider()
                .foregroundStyle(theme.cardBorder.opacity(0.3))

            // Content
            if isLoading {
                loadingState
            } else if filteredPrompts.isEmpty {
                emptyState
            } else {
                promptList
            }
        }
        .background(theme.cardBackground.opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
        )
        .shadow(color: theme.isDark ? .black.opacity(0.3) : .black.opacity(0.12), radius: 16, y: -4)
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.bottom, Spacing.xs)
        .frame(maxHeight: 320)
        .onChange(of: query) { _, _ in
            highlightedIndex = 0
        }
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Loading prompts…")
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.lg)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "text.book.closed")
                .scaledFont(size: 24)
                .foregroundStyle(theme.textTertiary.opacity(0.5))
            if prompts.isEmpty {
                Text("No prompts available")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                Text("Create prompts in your Open WebUI workspace")
                    .scaledFont(size: 11)
                    .foregroundStyle(theme.textTertiary.opacity(0.7))
            } else {
                Text("No prompts match \"/\(query)\"")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.lg)
    }

    // MARK: - Prompt List

    private var promptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredPrompts.enumerated()), id: \.element.id) { index, prompt in
                        promptRow(prompt, isHighlighted: index == highlightedIndex)
                            .id(prompt.id)
                            .onTapGesture {
                                onSelect(prompt)
                                Haptics.play(.light)
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: highlightedIndex) { _, newIndex in
                if newIndex < filteredPrompts.count {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(filteredPrompts[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Prompt Row

    private func promptRow(_ prompt: PromptItem, isHighlighted: Bool) -> some View {
        HStack(spacing: Spacing.sm) {
            // Command badge
            Text(prompt.displayCommand)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(theme.brandPrimary.opacity(0.1))
                )

            // Name & content preview
            VStack(alignment: .leading, spacing: 2) {
                Text(prompt.name)
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                if !prompt.content.isEmpty {
                    Text(prompt.content.prefix(80).replacingOccurrences(of: "\n", with: " "))
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Tags
            if !prompt.tags.isEmpty {
                HStack(spacing: 3) {
                    ForEach(prompt.tags.prefix(2), id: \.self) { tag in
                        Text(tag)
                            .scaledFont(size: 9, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(theme.surfaceContainer.opacity(0.8))
                            )
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
        .background(
            isHighlighted
                ? theme.brandPrimary.opacity(0.08)
                : Color.clear
        )
        .contentShape(Rectangle())
    }
}
