import SwiftUI

// MARK: - Knowledge Picker View

/// A floating popup that appears above the chat input when the user types `#`.
///
/// Shows three sections matching the OpenWebUI web client:
/// - **Folders**: Chat folders
/// - **Collections**: Knowledge bases (document groups with embeddings)
/// - **Files**: Knowledge-associated files (not raw uploads)
///
/// Filtered by the text typed after `#`. The picker uses a fixed height
/// layout to avoid SwiftUI layout bugs with dynamic sizing + keyboard.
struct KnowledgePickerView: View {
    let query: String
    let items: [KnowledgeItem]
    let isLoading: Bool
    let keyboardHeight: CGFloat
    let onSelect: (KnowledgeItem) -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme

    private var availableHeight: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        let screen = scene?.screen.bounds.height
            ?? UIScreen.main.bounds.height
        let topSafeArea = scene?.windows.first?.safeAreaInsets.top ?? 59
        let bottomSafeArea = scene?.windows.first?.safeAreaInsets.bottom ?? 34
        let reserved = topSafeArea + 44 + 16
        let usable = screen - reserved - keyboardHeight - bottomSafeArea - 56
        return max(120, usable)
    }

    // MARK: - Filtered Items

    private var filteredFolders: [KnowledgeItem] {
        let folders = items.filter { $0.type == .folder }
        guard !query.isEmpty else { return folders }
        return folders.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var filteredCollections: [KnowledgeItem] {
        let collections = items.filter { $0.type == .collection }
        guard !query.isEmpty else { return collections }
        return collections.filter {
            $0.name.localizedCaseInsensitiveContains(query)
            || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var filteredFiles: [KnowledgeItem] {
        let files = items.filter { $0.type == .file }
        guard !query.isEmpty else { return files }
        return files.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var hasResults: Bool {
        !filteredFolders.isEmpty || !filteredCollections.isEmpty || !filteredFiles.isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading && items.isEmpty {
                loadingView
            } else if !hasResults {
                emptyView
            } else {
                scrollContent
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: availableHeight)
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
            Text("Loading knowledge…")
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 24)
                .foregroundStyle(theme.textTertiary)
            Text(query.isEmpty ? "No knowledge sources" : "No results for \"\(query)\"")
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scroll Content

    private var scrollContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Folders section
                if !filteredFolders.isEmpty {
                    sectionHeader("Folders")
                    ForEach(filteredFolders) { item in
                        itemRow(item)
                    }
                }

                // Collections section
                if !filteredCollections.isEmpty {
                    sectionHeader("Collections")
                    ForEach(filteredCollections) { item in
                        itemRow(item)
                    }
                }

                // Files section
                if !filteredFiles.isEmpty {
                    sectionHeader("Files")
                    ForEach(filteredFiles) { item in
                        itemRow(item)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .scaledFont(size: 11, weight: .semibold)
            .textCase(.uppercase)
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    // MARK: - Item Row

    private func itemRow(_ item: KnowledgeItem) -> some View {
        Button {
            Haptics.play(.light)
            onSelect(item)
        } label: {
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(iconColor(for: item.type).opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: item.iconName)
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(iconColor(for: item.type))
                }

                // Name + subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    if let description = item.description, !description.isEmpty {
                        Text(description)
                            .scaledFont(size: 12, weight: .regular)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    } else if let count = item.fileCount, count > 0 {
                        Text("\(count) file\(count == 1 ? "" : "s")")
                            .scaledFont(size: 12, weight: .regular)
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(KnowledgeRowButtonStyle(theme: theme))
    }

    /// Returns a tinted color for each item type's icon.
    private func iconColor(for type: KnowledgeItem.KnowledgeType) -> Color {
        switch type {
        case .folder: return theme.brandPrimary
        case .collection: return theme.brandPrimary
        case .file: return theme.textSecondary
        }
    }
}

// MARK: - Row Button Style

private struct KnowledgeRowButtonStyle: ButtonStyle {
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
