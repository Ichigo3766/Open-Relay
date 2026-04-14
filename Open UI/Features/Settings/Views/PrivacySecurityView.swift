import SwiftUI

/// Privacy and security settings view.
struct PrivacySecurityView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @State private var clearDataConfirmation = false
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var showExportSheet = false
    @State private var exportError: String?


    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.sectionGap) {
                // Data Management
                SettingsSection(header: "Data Management") {
                    SettingsCell(
                        icon: "arrow.down.circle",
                        title: "Export Data",
                        subtitle: isExporting ? "Exporting..." : "Download your conversations as JSON",
                        showDivider: true,
                        accessory: isExporting ? .loading : .chevron
                    ) {
                        Task { await exportData() }
                    }

                    DestructiveSettingsCell(
                        icon: "trash",
                        title: "Clear Local Cache"
                    ) {
                        clearDataConfirmation = true
                    }
                }
            }
            .padding(.vertical, Spacing.lg)
        }
        .background(theme.background)
        .navigationTitle("Privacy & Security")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Clear Local Cache",
            isPresented: $clearDataConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                clearCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear cached images and temporary data. Your account and conversations are stored on the server and will not be affected.")
        }
        .sheet(isPresented: $showExportSheet, onDismiss: {
            // FIX: Clean up the temp export file after sharing to prevent data leaks.
            if let url = exportURL {
                try? FileManager.default.removeItem(at: url)
                exportURL = nil
            }
        }) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
        }
        .alert("Export Failed", isPresented: .init(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "Unknown error")
        }
    }

    private func infoRow(
        icon: String,
        title: String,
        url: String?,
        showDivider: Bool = true
    ) -> some View {
        SettingsCell(
            icon: icon,
            title: title,
            showDivider: showDivider,
            accessory: .chevron
        ) {
            if let urlString = url, let url = URL(string: urlString) {
                UIApplication.shared.open(url)
            }
        }
    }

    private func exportData() async {
        guard let manager = dependencies.conversationManager else { return }
        isExporting = true
        defer { isExporting = false }

        do {
            let conversations = try await manager.fetchConversations()
            let exportPayload: [[String: Any]] = conversations.map { conv in
                [
                    "id": conv.id,
                    "title": conv.title,
                    "created_at": conv.createdAt.timeIntervalSince1970,
                    "updated_at": conv.updatedAt.timeIntervalSince1970,
                    "model": conv.model ?? "",
                    "pinned": conv.pinned,
                    "archived": conv.archived,
                    "tags": conv.tags,
                    "message_count": conv.messages.count
                ]
            }

            let data = try JSONSerialization.data(withJSONObject: exportPayload, options: .prettyPrinted)
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("openui_export_\(Int(Date().timeIntervalSince1970)).json")
            try data.write(to: tempURL)
            exportURL = tempURL
            showExportSheet = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func clearCache() {
        // Clear URL cache
        URLCache.shared.removeAllCachedResponses()
        // Clear temporary files
        let tmp = FileManager.default.temporaryDirectory
        try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
            .forEach { try? FileManager.default.removeItem(at: $0) }
    }
}

// MARK: - Share Sheet

/// UIKit share sheet wrapper for presenting the system share activity.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}