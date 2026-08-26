import CoreLocation
import SwiftUI

/// Privacy and security settings view.
struct PrivacySecurityView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var showExportSheet = false
    @State private var exportError: String?
    @State private var showLocationDeniedAlert = false
    @State private var showDisableBiometricsConfirm = false
    @State private var excludeModelsFromBackup: Bool = StorageManager.excludeModelsFromBackup

    // API Key state
    @State private var currentApiKey: String? = nil
    @State private var isLoadingApiKey = false
    @State private var isGeneratingApiKey = false
    @State private var isDeletingApiKey = false
    @State private var showApiKeyCopied = false
    @State private var showDeleteApiKeyConfirm = false
    @State private var apiKeyError: String? = nil

    // Observe the shared LocationManager so the UI refreshes when auth status changes
    private var locationManager: LocationManager { LocationManager.shared }

    // Access AuthViewModel for biometric settings
    private var authVM: AuthViewModel { dependencies.authViewModel }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.sectionGap) {

                // Biometric Authentication (only shown when Face ID / Touch ID is available)
                if KeychainService.shared.isBiometricsAvailable {
                    SettingsSection(header: "Authentication") {
                        biometricRow
                    }
                }

                // Location
                SettingsSection(header: "Location") {
                    locationRow
                }

                // API Key Management
                SettingsSection(header: "API Key") {
                    apiKeySection
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

                    excludeFromBackupRow
                }
            }
            .padding(.vertical, Spacing.lg)
        }
        .background(theme.background)
        .navigationTitle("Privacy & Security")
        .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - Exclude from Backup Row

    @ViewBuilder
    private var excludeFromBackupRow: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.teal.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: "icloud.slash")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(Color.teal)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Exclude AI Models from Backup")
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                Text(excludeModelsFromBackup
                     ? "Models won't use iCloud storage — they're redownloadable"
                     : "AI models will be included in your iCloud backup")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { excludeModelsFromBackup },
                set: { newValue in
                    excludeModelsFromBackup = newValue
                    StorageManager.excludeModelsFromBackup = newValue
                }
            ))
            .labelsHidden()
            .tint(Color.teal)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Biometric Row

    @ViewBuilder
    private var biometricRow: some View {
        let typeName = authVM.biometricTypeName
        let iconName: String = {
            switch typeName {
            case "Face ID": return "faceid"
            case "Touch ID": return "touchid"
            default: return "faceid"
            }
        }()
        let isEnabled = authVM.biometricLoginEnabled
        let hasCredentials = authVM.canUseBiometricLogin || isEnabled

        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.purple.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: iconName)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(Color.purple)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(typeName)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                Text(biometricSubtitle(isEnabled: isEnabled, hasCredentials: hasCredentials))
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    if newValue {
                        // Can only enable if credentials are already saved
                        // (done automatically after manual login)
                        if authVM.currentServerURL != nil,
                           KeychainService.shared.hasBiometricCredentials(
                               forServer: authVM.currentServerURL ?? "") {
                            authVM.biometricLoginEnabled = true
                        } else {
                            // No credentials saved yet — turning on is a no-op;
                            // the user will be prompted to save after their next manual login.
                            authVM.biometricLoginEnabled = true
                        }
                    } else {
                        // Turning off: clear credentials and disable
                        authVM.clearBiometricCredentials()
                        authVM.biometricLoginEnabled = false
                    }
                }
            ))
            .labelsHidden()
            .tint(Color.purple)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func biometricSubtitle(isEnabled: Bool, hasCredentials: Bool) -> String {
        if !isEnabled {
            return "Sign in instantly without typing your password"
        }
        if hasCredentials {
            return "Enabled — sign in with \(authVM.biometricTypeName)"
        }
        return "Enabled — sign in manually once to save credentials"
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
}

// MARK: - API Key Section

extension PrivacySecurityView {

    /// The API Key section — shows the current key (masked), with Generate and Delete actions.
    @ViewBuilder
    var apiKeySection: some View {
        VStack(spacing: 0) {
            // Current key row
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "key.fill")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(Color.orange)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("API Key")
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textPrimary)
                    if isLoadingApiKey {
                        Text("Loading…")
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                    } else if let key = currentApiKey, !key.isEmpty {
                        Text(maskedKey(key))
                            .scaledFont(size: 12, design: .monospaced)
                            .foregroundStyle(theme.textSecondary)
                    } else {
                        Text("No API key — tap Generate to create one")
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                Spacer()

                // Copy button (only shown when key exists)
                if let key = currentApiKey, !key.isEmpty {
                    Button {
                        UIPasteboard.general.string = key
                        Haptics.notify(.success)
                        showApiKeyCopied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            showApiKeyCopied = false
                        }
                    } label: {
                        Image(systemName: showApiKeyCopied ? "checkmark" : "doc.on.doc")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(showApiKeyCopied ? Color.green : theme.brandPrimary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Error message if any
            if let error = apiKeyError {
                Divider().padding(.leading, 16)
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.error)
                    Text(error)
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.error)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Divider().padding(.leading, 16)

            // Generate button row
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.brandPrimary.opacity(0.12))
                        .frame(width: 32, height: 32)
                    if isGeneratingApiKey {
                        ProgressView().controlSize(.small).tint(theme.brandPrimary)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(theme.brandPrimary)
                    }
                }

                Text(currentApiKey != nil ? "Regenerate API Key" : "Generate API Key")
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.brandPrimary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isGeneratingApiKey else { return }
                Task { await generateApiKey() }
            }

            // Delete button row (only when key exists)
            if currentApiKey != nil {
                Divider().padding(.leading, 16)

                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.error.opacity(0.12))
                            .frame(width: 32, height: 32)
                        if isDeletingApiKey {
                            ProgressView().controlSize(.small).tint(theme.error)
                        } else {
                            Image(systemName: "trash")
                                .scaledFont(size: 13, weight: .medium)
                                .foregroundStyle(theme.error)
                        }
                    }

                    Text("Revoke API Key")
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.error)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isDeletingApiKey else { return }
                    showDeleteApiKeyConfirm = true
                }
                .confirmationDialog(
                    "Revoke API Key?",
                    isPresented: $showDeleteApiKeyConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Revoke API Key", role: .destructive) {
                        Task { await deleteApiKey() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will immediately invalidate your API key. Any apps using it will stop working.")
                }
            }
        }
        .task {
            await loadApiKey()
        }
    }

    private func loadApiKey() async {
        guard let api = dependencies.apiClient else { return }
        isLoadingApiKey = true
        apiKeyError = nil
        currentApiKey = try? await api.getApiKey()
        isLoadingApiKey = false
    }

    private func generateApiKey() async {
        guard let api = dependencies.apiClient else { return }
        isGeneratingApiKey = true
        apiKeyError = nil
        do {
            let newKey = try await api.generateApiKey()
            currentApiKey = newKey
            Haptics.notify(.success)
        } catch {
            let apiErr = APIError.from(error)
            apiKeyError = apiErr.errorDescription ?? "Failed to generate API key."
        }
        isGeneratingApiKey = false
    }

    private func deleteApiKey() async {
        guard let api = dependencies.apiClient else { return }
        isDeletingApiKey = true
        apiKeyError = nil
        do {
            try await api.deleteApiKey()
            currentApiKey = nil
            Haptics.notify(.success)
        } catch {
            let apiErr = APIError.from(error)
            apiKeyError = apiErr.errorDescription ?? "Failed to revoke API key."
        }
        isDeletingApiKey = false
    }

    /// Returns a masked version of the key showing first 8 and last 4 chars.
    private func maskedKey(_ key: String) -> String {
        guard key.count > 12 else { return String(repeating: "•", count: key.count) }
        let prefix = String(key.prefix(8))
        let suffix = String(key.suffix(4))
        let dots = String(repeating: "•", count: min(16, key.count - 12))
        return "\(prefix)\(dots)\(suffix)"
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
