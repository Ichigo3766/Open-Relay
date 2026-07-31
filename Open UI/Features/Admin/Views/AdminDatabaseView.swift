import SwiftUI
import UniformTypeIdentifiers

// MARK: - Admin Database View

/// The admin "Database" tab — import/export admin config, export all chats.
struct AdminDatabaseView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminDatabaseViewModel()
    @State private var showImportPicker = false
    @State private var exportConfigData: Data? = nil
    @State private var exportChatsData: Data? = nil
    @State private var importError: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                configSection
                exportSection
                Spacer(minLength: 80)
            }
            .padding(.top, Spacing.md)
        }
        .background(theme.background)
        .task {
            viewModel.configure(apiClient: dependencies.apiClient)
        }
        // Import file picker
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        await viewModel.importConfig(data)
                        importError = viewModel.error
                    } else {
                        importError = "Could not read file."
                    }
                }
            case .failure(let err):
                importError = err.localizedDescription
            }
        }
        // Export config share sheet
        .sheet(isPresented: Binding(
            get: { exportConfigData != nil },
            set: { if !$0 { exportConfigData = nil } }
        )) {
            if let data = exportConfigData {
                AdminShareSheetWrapper(items: [data], fileName: "config-\(Int(Date().timeIntervalSince1970)).json")
            }
        }
        // Export chats share sheet
        .sheet(isPresented: Binding(
            get: { exportChatsData != nil },
            set: { if !$0 { exportChatsData = nil } }
        )) {
            if let data = exportChatsData {
                AdminShareSheetWrapper(items: [data], fileName: "all-chats-\(Int(Date().timeIntervalSince1970)).json")
            }
        }
    }

    // MARK: - Config Section

    private var configSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "doc.badge.gearshape", title: "Config")

            SettingsSection {
                actionRow(
                    title: "Import Config",
                    subtitle: "Restore admin configuration from a JSON export file.",
                    icon: "square.and.arrow.down",
                    isLoading: viewModel.isImportingConfig
                ) {
                    importError = nil
                    showImportPicker = true
                }

                Divider().padding(.leading, Spacing.md)

                actionRow(
                    title: "Export Config",
                    subtitle: "Download the current admin configuration as JSON.",
                    icon: "square.and.arrow.up",
                    isLoading: viewModel.isExportingConfig
                ) {
                    Task {
                        if let data = try? await viewModel.exportConfig() {
                            exportConfigData = data
                        }
                    }
                }
            }

            if let err = importError ?? viewModel.error {
                errorBanner(err)
            }

            if let msg = viewModel.successMessage {
                successBanner(msg)
            }
        }
    }

    // MARK: - Export Section

    private var exportSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "arrow.down.doc", title: "Export")

            SettingsSection(footer: "Download data from the server for backup or analysis.") {
                actionRow(
                    title: "Export All Chats",
                    subtitle: "Download every user's chat history as JSON.",
                    icon: "bubble.left.and.bubble.right",
                    isLoading: viewModel.isExportingChats
                ) {
                    Task {
                        if let data = try? await viewModel.exportAllChats() {
                            exportChatsData = data
                        }
                    }
                }
            }
        }
    }

    // MARK: - Row Builders

    private func actionRow(
        title: String,
        subtitle: String? = nil,
        icon: String,
        isLoading: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
                    .frame(width: 60, height: 28)
            } else {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Image(systemName: icon)
                            .scaledFont(size: 13)
                        Text(title.components(separatedBy: " ").first ?? title)
                            .scaledFont(size: 13, weight: .medium)
                    }
                    .foregroundStyle(theme.brandPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.brandPrimary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.chatBubblePadding)
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
            Text(title.uppercased())
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .tracking(0.8)
            Spacer()
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.circle.fill")
                .scaledFont(size: 12)
                .foregroundStyle(theme.error)
            Text(message)
                .scaledFont(size: 12)
                .foregroundStyle(theme.error)
                .lineLimit(3)
            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(theme.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
        .padding(.horizontal, Spacing.screenPadding)
    }

    private func successBanner(_ message: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 12)
                .foregroundStyle(.green)
            Text(message)
                .scaledFont(size: 12)
                .foregroundStyle(.green)
            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
        .padding(.horizontal, Spacing.screenPadding)
    }
}

// MARK: - Share Sheet Wrapper with custom filename

struct AdminShareSheetWrapper: UIViewControllerRepresentable {
    let items: [Any]
    let fileName: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Write data to a temp file with the desired filename so iOS uses it
        if let data = items.first as? Data,
           let tempDir = try? FileManager.default.url(
               for: .itemReplacementDirectory,
               in: .userDomainMask,
               appropriateFor: FileManager.default.temporaryDirectory,
               create: true
           ) {
            let fileURL = tempDir.appendingPathComponent(fileName)
            try? data.write(to: fileURL)
            return UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        }
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
