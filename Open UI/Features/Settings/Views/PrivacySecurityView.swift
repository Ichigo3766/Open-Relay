import CoreLocation
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
    @State private var showLocationDeniedAlert = false

    // Observe the shared LocationManager so the UI refreshes when auth status changes
    private var locationManager: LocationManager { LocationManager.shared }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.sectionGap) {

                // Location
                SettingsSection(header: "Location") {
                    locationRow
                }

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
        .alert("Location Access Denied", isPresented: $showLocationDeniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Open Relay needs location access to use {{USER_LOCATION}} in prompts. Please enable it in Settings > Privacy & Security > Location Services.")
        }
    }

    // MARK: - Location Row

    @ViewBuilder
    private var locationRow: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: "location.fill")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(Color.blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Share Location")
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                Text(locationSubtitle)
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { locationManager.isLocationEnabled },
                set: { newValue in
                    handleLocationToggle(newValue)
                }
            ))
            .labelsHidden()
            .tint(Color.blue)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var locationSubtitle: String {
        let status = locationManager.authorizationStatus
        if !locationManager.isLocationEnabled {
            return "Enable to use {{USER_LOCATION}} in prompts"
        }
        switch status {
        case .notDetermined:
            return "Tap to request location permission"
        case .denied, .restricted:
            return "Location access denied — tap to open Settings"
        case .authorizedWhenInUse, .authorizedAlways:
            if locationManager.cachedLocation != nil {
                // Prefer human-readable place name; fall back to coords while geocoding
                let place = locationManager.cachedPlaceName ?? locationManager.locationString ?? ""
                return "Active · \(place)"
            }
            return "Waiting for GPS fix…"
        @unknown default:
            return "Enable to use {{USER_LOCATION}} in prompts"
        }
    }

    private func handleLocationToggle(_ newValue: Bool) {
        if newValue {
            let status = locationManager.authorizationStatus
            if status == .denied || status == .restricted {
                // Can't ask again — send user to Settings
                showLocationDeniedAlert = true
                return
            }
            locationManager.isLocationEnabled = true
            locationManager.requestPermissionAndStart()
        } else {
            locationManager.isLocationEnabled = false
        }
    }

    // MARK: - Helpers

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
