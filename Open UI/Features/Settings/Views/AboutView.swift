import SwiftUI

/// About screen showing app version, server info, and links.
struct AboutView: View {
    @Bindable var viewModel: AuthViewModel
    @Environment(\.theme) private var theme

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.sectionGap) {
                // App icon and version
                appHeader

                // App info
                SettingsSection(header: "App") {
                    detailRow(label: "Version", value: appVersion)
                    detailRow(label: "Build", value: buildNumber)
                    detailRow(label: "Platform", value: "iOS \(UIDevice.current.systemVersion)", showDivider: false)
                }

                // Server info
                SettingsSection(header: "Server") {
                    detailRow(label: "Name", value: viewModel.serverName)
                    if let version = viewModel.serverVersion {
                        detailRow(label: "Server Version", value: version)
                    }
                    detailRow(
                        label: "URL",
                        value: viewModel.serverURL,
                        showDivider: false
                    )
                }

                // Links
                SettingsSection(header: "Links") {
                    linkRow(
                        icon: "safari",
                        title: "Open WebUI Website",
                        url: "https://openwebui.com"
                    )
                    linkRow(
                        icon: "curlybraces",
                        title: "Source Code",
                        url: "https://github.com/Ichigo3766/Open-UI"
                    )
                    linkRow(
                        icon: "questionmark.circle",
                        title: "Help & Support",
                        url: "https://github.com/Ichigo3766/Open-UI/issues"
                    )
                    linkRow(
                        icon: "hand.raised",
                        title: "Privacy Policy",
                        url: "https://github.com/Ichigo3766/Open-UI/blob/main/PRIVACY.md",
                        showDivider: false
                    )
                }

                // Credits
                VStack(spacing: Spacing.sm) {
                    Text("Made with ❤️ for Open WebUI")
                        .font(AppTypography.captionFont)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.vertical, Spacing.lg)
            }
            .padding(.vertical, Spacing.lg)
        }
        .background(theme.background)
    }

    private var appHeader: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 56))
                .foregroundStyle(theme.brandPrimary)
                .frame(width: 88, height: 88)
                .background(theme.brandPrimary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Text("Open UI")
                .font(AppTypography.headlineLargeFont)
                .foregroundStyle(theme.textPrimary)

            Text("A native iOS client for Open WebUI")
                .font(AppTypography.bodySmallFont)
                .foregroundStyle(theme.textSecondary)

            Text("v\(appVersion) (\(buildNumber))")
                .font(AppTypography.captionFont)
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.top, Spacing.lg)
    }

    private func detailRow(
        label: String,
        value: String,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(AppTypography.bodySmallFont)
                    .foregroundStyle(theme.textSecondary)

                Spacer()

                Text(value)
                    .font(AppTypography.bodySmallFont)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            if showDivider {
                Divider()
                    .padding(.leading, Spacing.md)
            }
        }
    }

    private func linkRow(
        icon: String,
        title: String,
        url: String,
        showDivider: Bool = true
    ) -> some View {
        SettingsCell(
            icon: icon,
            title: title,
            showDivider: showDivider,
            accessory: .chevron
        ) {
            if let url = URL(string: url) {
                UIApplication.shared.open(url)
            }
        }
    }
}
