import SwiftUI

// MARK: - Model Picker View

/// A floating popup that appears above the chat input when the user types `@`.
///
/// Shows available AI models filtered by the text typed after `@`.
/// Mirrors the design of `KnowledgePickerView` for visual consistency.
struct ModelPickerView: View {
    let query: String
    let models: [AIModel]
    let serverBaseURL: String
    let authToken: String?
    let onSelect: (AIModel) -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme

    // MARK: - Filtered Models

    private var filteredModels: [AIModel] {
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.name.localizedCaseInsensitiveContains(query)
            || $0.shortName.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if models.isEmpty {
                loadingView
            } else if filteredModels.isEmpty {
                emptyView
            } else {
                scrollContent
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 280)
        .background(pickerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(
            color: theme.isDark ? Color.black.opacity(0.4) : Color.black.opacity(0.12),
            radius: 16, x: 0, y: -4
        )
        .padding(.horizontal, Spacing.screenPadding)
    }

    // MARK: - Background

    private var pickerBackground: some View {
        Group {
            if theme.isDark {
                theme.cardBackground.opacity(0.98)
            } else {
                Color(.systemBackground).opacity(0.98)
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Loading models…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(theme.textTertiary)
            Text("No models match \"\(query)\"")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scroll Content

    private var scrollContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionHeader("Models")
                ForEach(filteredModels) { model in
                    modelRow(model)
                }
            }
            .padding(.vertical, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
    }

    // MARK: - Model Row

    private func modelRow(_ model: AIModel) -> some View {
        Button {
            Haptics.play(.light)
            onSelect(model)
        } label: {
            HStack(spacing: 12) {
                // Avatar
                ModelAvatar(
                    size: 36,
                    imageURL: model.resolveAvatarURL(baseURL: serverBaseURL),
                    label: model.shortName,
                    authToken: authToken
                )

                // Name + description
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.shortName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    if let desc = model.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(ModelRowButtonStyle(theme: theme))
    }
}

// MARK: - Row Button Style

private struct ModelRowButtonStyle: ButtonStyle {
    let theme: AppTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? theme.brandPrimary.opacity(0.08)
                    : Color.clear
            )
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
