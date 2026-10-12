import SwiftUI

/// Settings › Privacy & Security › Two-Factor Sign-In.
/// Hidden on servers without MFA support (status endpoint missing).
struct TwoFactorSettingsSection: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var status: MfaStatus?
    @State private var showManage = false

    var body: some View {
        Group {
            if let status {
                SettingsSection(
                    header: String(localized: "Two-Factor Sign-In"),
                    footer: status.enabled
                        ? String(localized: "\(status.recoveryCodesRemaining) recovery codes remaining")
                        : String(localized: "Managed by your administrator.")
                ) {
                    SettingsCell(
                        icon: "lock.shield",
                        title: status.enabled
                            ? String(localized: "Authenticator configured")
                            : String(localized: "Authenticator not configured"),
                        subtitle: status.required && status.enabled
                            ? String(localized: "Replace your authenticator or create new recovery codes")
                            : nil,
                        showDivider: false,
                        accessory: status.required && status.enabled ? .chevron : .none
                    ) {
                        if status.required && status.enabled { showManage = true }
                    }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showManage, onDismiss: { Task { await load() } }) {
            TwoFactorManageSheet(accountLabel: dependencies.authViewModel.currentUser?.email ?? "")
        }
    }

    private func load() async {
        guard let client = dependencies.apiClient else { return }
        // Older servers return 404 — keep the section hidden.
        status = try? await client.mfaStatus()
    }
}
