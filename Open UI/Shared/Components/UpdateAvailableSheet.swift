import SwiftUI
import MarkdownView

/// Dismissable sheet shown when a newer version of Open Relay is available on the App Store.
/// Displays the version number and the release notes rendered as markdown.
struct UpdateAvailableSheet: View {
    let update: AppUpdateInfo
    let onUpdate: () -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityScale) private var accessibilityScale

    private static let appStoreURL = URL(string: "https://apps.apple.com/app/id6759630325")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // MARK: Header
                    headerSection
                        .padding(.top, 28)
                        .padding(.bottom, 24)

                    Divider()
                        .padding(.horizontal, 20)

                    // MARK: Release Notes
                    if !update.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        releaseNotesSection
                            .padding(.top, 20)
                            .padding(.horizontal, 20)
                    }

                    // MARK: Buttons
                    buttonSection
                        .padding(.top, 24)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                }
            }
            .background(theme.background)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark") {
                        onDismiss()
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                    .tint(.secondary)
                    .accessibilityLabel("Dismiss")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            // App icon
            Image("AppIconImage")
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)

            VStack(spacing: 6) {
                // Badge
                Text("Update Available")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.accentColor)
                    )

                // Version
                Text("Version \(update.version)")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(theme.textPrimary)

                // Subtitle
                Text("A new version of Open Relay is ready.")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    // MARK: - Release Notes

    private var releaseNotesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Use MarkdownView for proper rendering of headings + bullet lists
            MarkdownView(update.releaseNotes, theme: releaseNotesTheme)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A slightly smaller markdown theme for release notes text.
    private var releaseNotesTheme: MarkdownTheme {
        let scale = accessibilityScale.scale(for: .content)
        var theme = MarkdownTheme.default
        // Scale down slightly from the default body font
        let baseFontSize = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
        theme.align(to: baseFontSize * scale)
        return theme
    }

    // MARK: - Buttons

    private var buttonSection: some View {
        VStack(spacing: 10) {
            // Primary: Update on App Store
            Button {
                UIApplication.shared.open(Self.appStoreURL)
                onDismiss()
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Update on App Store")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            // Secondary: Later
            Button {
                onDismiss()
                dismiss()
            } label: {
                Text("Later")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
        }
    }
}
