import SwiftUI

// MARK: - Admin Settings Tab

/// The Settings section of the Admin Console.
/// Shows a sidebar list of settings categories (like Open WebUI's web UI)
/// and renders the selected section's content on tap.
struct AdminSettingsTab: View {
    @Environment(\.theme) private var theme
    @State private var selectedSection: SettingsSubSection = .general
    @State private var searchQuery = ""
    @State private var showSectionSheet = false

    var filteredSections: [SettingsSubSection] {
        guard !searchQuery.isEmpty else { return SettingsSubSection.allCases }
        return SettingsSubSection.allCases.filter {
            $0.searchableText.contains(searchQuery.lowercased())
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sub-tab pill bar (same style as Users sub-tabs)
            settingsSidebarBar
                .padding(.top, Spacing.xs)
                .padding(.bottom, Spacing.xs)

            Divider()
                .background(theme.inputBorder.opacity(0.2))

            // Content for the selected section
            settingsContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sidebar Bar (horizontal scrollable list of sections)

    private var settingsSidebarBar: some View {
        VStack(spacing: Spacing.xs) {
            // Search bar
            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                TextField("Search", text: $searchQuery)
                    .scaledFont(size: 14)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 7)
            .background(theme.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                    .strokeBorder(theme.cardBorder, lineWidth: 0.5)
            )
            .padding(.horizontal, Spacing.screenPadding)

            // Horizontal scrollable section pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(filteredSections, id: \.self) { section in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selectedSection = section
                            }
                            Haptics.play(.light)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: section.icon)
                                    .scaledFont(size: 12, weight: .medium)
                                Text(section.displayName)
                                    .scaledFont(size: 13, weight: selectedSection == section ? .semibold : .regular)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            .foregroundStyle(selectedSection == section ? theme.brandPrimary : theme.textTertiary)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .background(
                                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                                    .fill(selectedSection == section
                                          ? theme.brandPrimary.opacity(0.12)
                                          : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                                    .strokeBorder(
                                        selectedSection == section ? theme.brandPrimary.opacity(0.3) : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.vertical, Spacing.xs)
            }
        }
    }

    // MARK: - Section Content

    @ViewBuilder
    private var settingsContent: some View {
        switch selectedSection {
        case .general:
            AdminGeneralSettingsView()
        case .connections:
            AdminConnectionsView()
        case .integrations:
            AdminIntegrationsView()
        case .documents:
            AdminDocumentsView()
        case .webSearch:
            AdminWebSearchView()
        case .codeExecution:
            AdminCodeExecutionView()
        case .interface_:
            AdminInterfaceView()
        case .audio:
            AdminAudioView()
        case .images:
            AdminImagesView()
        }
    }
}
