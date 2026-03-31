import SwiftUI

// MARK: - Settings Section

/// A grouped settings section with an optional header and footer.
///
/// Usage:
/// ```swift
/// SettingsSection(header: "Account") {
///     SettingsCell(icon: "person", title: "Profile")
///     SettingsCell(icon: "key", title: "Password")
/// }
/// ```
struct SettingsSection<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(LocalizedStringKey(header))
                    .textCase(.uppercase)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .tracking(0.8)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.bottom, Spacing.sm)
            }

            VStack(spacing: 0) {
                content()
            }
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .strokeBorder(theme.cardBorder, lineWidth: 0.5)
            )
            .padding(.horizontal, Spacing.screenPadding)

            if let footer {
                Text(footer)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.screenPadding + Spacing.md)
                    .padding(.top, Spacing.sm)
            }
        }
    }
}

// MARK: - Settings Cell

/// A single settings row with an icon, title, optional subtitle, and
/// an accessory on the trailing edge.
struct SettingsCell: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var iconColor: Color? = nil
    var showDivider: Bool = true
    var accessory: SettingsAccessory = .chevron
    var action: (() -> Void)? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: { action?() }) {
            VStack(spacing: 0) {
                HStack(spacing: Spacing.md) {
                    // Icon
                    iconView

                    // Title & subtitle
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(LocalizedStringKey(title))
                            .scaledFont(size: 16)
                            .foregroundStyle(theme.textPrimary)

                        if let subtitle {
                            Text(LocalizedStringKey(subtitle))
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                        }
                    }

                    Spacer()

                    // Accessory
                    accessoryView
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.chatBubblePadding)
                .contentShape(Rectangle())

                if showDivider {
                    Divider()
                        .padding(.leading, Spacing.md + IconSize.lg + Spacing.md)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var iconView: some View {
        Image(systemName: icon)
            .scaledFont(size: 16, weight: .medium)
            .foregroundStyle(iconColor ?? theme.brandPrimary)
            .frame(width: IconSize.lg, height: IconSize.lg)
            .background((iconColor ?? theme.brandPrimary).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .chevron:
            Image(systemName: "chevron.right")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
        case .text(let value):
            Text(value)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textTertiary)
        case .badge(let value):
            Text(value)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xxs)
                .background(theme.error)
                .clipShape(Capsule())
        case .toggle(let isOn, let onChange):
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { onChange($0) }
            ))
            .labelsHidden()
            .tint(theme.brandPrimary)
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Settings Accessory

/// The trailing accessory type for a settings cell.
enum SettingsAccessory {
    case chevron
    case text(String)
    case badge(String)
    case toggle(isOn: Bool, onChange: (Bool) -> Void)
    case loading
    case none
}

// MARK: - Destructive Settings Cell

/// A settings cell styled for destructive actions (e.g., sign out, delete).
struct DestructiveSettingsCell: View {
    let icon: String
    let title: String
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(theme.error)
                    .frame(width: IconSize.lg, height: IconSize.lg)
                    .background(theme.error.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text(LocalizedStringKey(title))
                    .scaledFont(size: 16)
                    .foregroundStyle(theme.error)

                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - Settings Header Cell

/// A settings section header with a user avatar and name.
struct SettingsProfileHeader: View {
    let name: String
    var email: String? = nil
    var avatarURL: URL? = nil
    var authToken: String? = nil
    var onTap: (() -> Void)? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: Spacing.md) {
                UserAvatar(size: 56, imageURL: avatarURL, name: name, authToken: authToken)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(name)
                        .scaledFont(size: 20, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)

                    if let email {
                        Text(email)
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                Spacer()

                if onTap != nil {
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#Preview("Settings") {
    ScrollView {
        VStack(spacing: Spacing.sectionGap) {
            SettingsSection(header: "Account") {
                SettingsProfileHeader(name: "Alice Johnson", email: "alice@example.com")
            }

            SettingsSection(header: "General") {
                SettingsCell(icon: "globe", title: "Language", accessory: .text("English"))
                SettingsCell(icon: "moon", title: "Dark Mode", accessory: .toggle(isOn: true, onChange: { _ in }))
                SettingsCell(icon: "bell", title: "Notifications", showDivider: false)
            }

            SettingsSection(header: "Models", footer: "Choose your default AI model for new conversations.") {
                SettingsCell(icon: "cpu", title: "Default Model", accessory: .text("GPT-4"))
                SettingsCell(icon: "slider.horizontal.3", title: "Parameters", showDivider: false)
            }

            SettingsSection {
                DestructiveSettingsCell(icon: "rectangle.portrait.and.arrow.right", title: "Sign Out", action: {})
            }
        }
        .padding(.vertical, Spacing.lg)
    }
    .background(Color(hex: 0xF5F5F5))
    .themed()
}
