import SwiftUI
import MarkdownView

// MARK: - Combined Updates Sheet

/// Sheet shown when one or both of (app update, server update) are available.
/// If both are available, renders them as two sections in a single scrollable sheet.
/// If only one is available, renders just that section.
struct CombinedUpdateSheet: View {
    let appUpdate: AppUpdateInfo?
    let serverUpdate: ServerUpdateInfo?
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityScale) private var accessibilityScale

    private static let appStoreURL = URL(string: "https://apps.apple.com/app/id6759630325")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if let app = appUpdate, let server = serverUpdate {
                        // Both updates available — show both sections
                        appUpdateSection(app)
                            .padding(.top, 24)

                        Divider()
                            .padding(.horizontal, 20)
                            .padding(.vertical, 4)

                        serverUpdateSection(server)
                            .padding(.bottom, 8)

                        buttonSection(appUpdate: app, serverUpdate: server)
                            .padding(.top, 16)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 32)

                    } else if let app = appUpdate {
                        // App update only
                        appUpdateSection(app)
                            .padding(.top, 28)
                            .padding(.bottom, 24)

                        Divider()
                            .padding(.horizontal, 20)

                        if !app.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            appReleaseNotesSection(app.releaseNotes)
                                .padding(.top, 20)
                                .padding(.horizontal, 20)
                        }

                        buttonSection(appUpdate: app, serverUpdate: nil)
                            .padding(.top, 24)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 32)

                    } else if let server = serverUpdate {
                        // Server update only
                        serverUpdateSection(server)
                            .padding(.top, 28)
                            .padding(.bottom, 8)

                        if let markdown = server.changelogMarkdown,
                           !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Divider()
                                .padding(.horizontal, 20)
                            serverChangelogSection(markdown)
                                .padding(.top, 20)
                                .padding(.horizontal, 20)
                        }

                        buttonSection(appUpdate: nil, serverUpdate: server)
                            .padding(.top, 24)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 32)
                    }
                }
            }
            .background(theme.background)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onDismiss()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(theme.textTertiary)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel("Dismiss")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - App Update Section

    @ViewBuilder
    private func appUpdateSection(_ update: AppUpdateInfo) -> some View {
        VStack(spacing: 12) {
            Image("AppIconImage")
                .resizable()
                .scaledToFill()
                .frame(width: appUpdate != nil && serverUpdate != nil ? 56 : 72,
                       height: appUpdate != nil && serverUpdate != nil ? 56 : 72)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)

            VStack(spacing: 6) {
                badgeView(text: "App Update Available", color: .accentColor)

                Text("Open Relay \(update.version)")
                    .font(.system(size: appUpdate != nil && serverUpdate != nil ? 18 : 22, weight: .bold))
                    .foregroundStyle(theme.textPrimary)

                Text("A new version of Open Relay is ready.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if appUpdate != nil && serverUpdate != nil,
                   !update.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appReleaseNotesSection(update.releaseNotes)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Server Update Section

    @ViewBuilder
    private func serverUpdateSection(_ update: ServerUpdateInfo) -> some View {
        let iconSize: CGFloat = appUpdate != nil && serverUpdate != nil ? 56 : 72
        // Open WebUI serves its icon at /static/favicon.png
        let faviconURL: URL? = URL(string: "\(update.serverURL)/static/favicon.png")

        VStack(spacing: 12) {
            CachedAsyncImage(url: faviconURL) { image in
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: iconSize, height: iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
            } placeholder: {
                // Fallback: blue rounded square with server.rack icon
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: iconSize, height: iconSize)
                    Image(systemName: "server.rack")
                        .font(.system(size: appUpdate != nil && serverUpdate != nil ? 24 : 30, weight: .medium))
                        .foregroundStyle(Color.blue)
                }
            }

            VStack(spacing: 6) {
                badgeView(text: "Server Update Available", color: .blue)

                Text("Open WebUI \(update.version)")
                    .font(.system(size: appUpdate != nil && serverUpdate != nil ? 18 : 22, weight: .bold))
                    .foregroundStyle(theme.textPrimary)

                Text(update.serverName)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)

                Text("Your Open WebUI server has a new version available.\nContact your administrator to update.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if appUpdate != nil && serverUpdate != nil,
                   let markdown = update.changelogMarkdown,
                   !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    serverChangelogSection(markdown)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, appUpdate != nil ? 16 : 0)
    }

    // MARK: - Server Changelog (GitHub Releases markdown)

    /// Renders the GitHub release body markdown via MarkdownView — full formatting,
    /// emoji, bold text, and section headers exactly as they appear on the release page.
    @ViewBuilder
    private func serverChangelogSection(_ markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What's in this update")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textPrimary)

            MarkdownView(markdown, theme: markdownTheme)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - App Release Notes (MarkdownView)

    @ViewBuilder
    private func appReleaseNotesSection(_ markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkdownView(markdown, theme: markdownTheme)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var markdownTheme: MarkdownTheme {
        let scale = accessibilityScale.scale(for: .content)
        var t = MarkdownTheme.default
        let baseFontSize = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
        t.align(to: baseFontSize * scale)
        return t
    }

    // MARK: - Shared Subviews

    private func badgeView(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color))
    }

    // MARK: - Buttons

    @ViewBuilder
    private func buttonSection(appUpdate: AppUpdateInfo?, serverUpdate: ServerUpdateInfo?) -> some View {
        VStack(spacing: 10) {
            if appUpdate != nil {
                Button {
                    UIApplication.shared.open(Self.appStoreURL)
                    onDismiss()
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.app.fill")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Update App on App Store")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            Button {
                onDismiss()
                dismiss()
            } label: {
                Text(appUpdate != nil ? "Later" : "Got It")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
        }
    }
}
