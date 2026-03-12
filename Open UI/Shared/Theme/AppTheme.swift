import SwiftUI

// MARK: - App Theme

/// Central theme object that provides semantic colors, typography, and
/// component-specific styling derived from the ``ColorTokens`` system
/// and the user's chosen accent color.
///
/// Access the current theme via the environment:
/// ```swift
/// @Environment(\.theme) private var theme
/// ```
struct AppTheme: Equatable, Sendable {

    let colorScheme: ColorScheme
    let tokens: ColorTokens
    let accent: AppearanceManager.AccentColorPreset
    let usePureBlack: Bool
    let useTintedBackgrounds: Bool
    let customColor: Color?

    init(
        colorScheme: ColorScheme = .light,
        accent: AppearanceManager.AccentColorPreset = .blue,
        usePureBlack: Bool = false,
        useTintedBackgrounds: Bool = false,
        customColor: Color? = nil
    ) {
        self.colorScheme = colorScheme
        self.tokens = .resolved(for: colorScheme)
        self.accent = accent
        self.usePureBlack = usePureBlack
        self.useTintedBackgrounds = useTintedBackgrounds
        self.customColor = customColor
    }

    // Equatable conformance: compare the inputs that produce the theme
    static func == (lhs: AppTheme, rhs: AppTheme) -> Bool {
        lhs.colorScheme == rhs.colorScheme
            && lhs.accent == rhs.accent
            && lhs.usePureBlack == rhs.usePureBlack
            && lhs.useTintedBackgrounds == rhs.useTintedBackgrounds
            && lhs.customColorHex == rhs.customColorHex
    }

    /// Stable hex representation of the custom color for Equatable comparison.
    private var customColorHex: String? {
        guard let c = customColor else { return nil }
        let ui = UIColor(c)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    var isDark: Bool { colorScheme == .dark }

    // MARK: - Accent Colors (Dynamic)

    /// The primary accent color, resolved for the current color scheme.
    var accentColor: Color {
        if let customColor { return customColor }
        return accent.resolved(for: colorScheme)
    }

    /// The text/icon color to use on top of the accent color.
    var onAccentColor: Color {
        if customColor != nil {
            // Determine contrast color for custom color
            let uiColor = UIColor(accentColor)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            let luminance = 0.299 * r + 0.587 * g + 0.114 * b
            return luminance > 0.5 ? Color(hex: 0x0A0A0A) : .white
        }
        return accent.resolvedOnAccent(for: colorScheme)
    }

    /// A subtle tinted background using the accent color.
    var accentTint: Color {
        if customColor != nil {
            return accentColor.opacity(isDark ? 0.12 : 0.08)
        }
        return isDark ? accent.darkTintedBackground : accent.lightTintedBackground
    }

    // MARK: - Surface Colors

    var background: Color {
        if useTintedBackgrounds {
            return isDark
                ? (usePureBlack ? Color(hex: 0x000000) : Color(hex: 0x0A0A0A))
                : Color(hex: 0xFCFCFC).blend(with: accentColor, amount: 0.02)
        }
        if isDark && usePureBlack {
            return Color(hex: 0x000000)
        }
        return tokens.neutralTone00
    }

    var surfaceContainer: Color {
        if useTintedBackgrounds {
            return isDark
                ? Color(hex: 0x121212).blend(with: accentColor, amount: 0.04)
                : Color(hex: 0xFAFAFA).blend(with: accentColor, amount: 0.03)
        }
        return tokens.neutralTone10
    }

    var surfaceContainerHighest: Color {
        if useTintedBackgrounds {
            return isDark
                ? Color(hex: 0x1A1A1A).blend(with: accentColor, amount: 0.06)
                : Color(hex: 0xF5F5F5).blend(with: accentColor, amount: 0.04)
        }
        return tokens.neutralTone20
    }

    var cardBackground: Color {
        if useTintedBackgrounds {
            return isDark
                ? Color(hex: 0x171717).blend(with: accentColor, amount: 0.05)
                : Color(hex: 0xFFFFFF).blend(with: accentColor, amount: 0.02)
        }
        return tokens.neutralTone20
    }

    var cardBorder: Color { isDark ? tokens.neutralTone40 : Color(hex: 0xE5E5E5) }

    // MARK: - Text Colors

    var textPrimary: Color { tokens.neutralOnSurface }
    var textSecondary: Color { tokens.neutralTone80 }
    var textTertiary: Color { tokens.neutralTone60 }
    var textInverse: Color { tokens.neutralTone00 }
    var textDisabled: Color { isDark ? tokens.neutralTone40 : tokens.neutralTone60 }

    // MARK: - Icon Colors

    var iconPrimary: Color { tokens.neutralOnSurface }
    var iconSecondary: Color { tokens.neutralTone80 }
    var iconDisabled: Color { isDark ? tokens.neutralTone40 : tokens.neutralTone60 }

    // MARK: - Brand / Accent Colors (Semantic)

    var brandPrimary: Color { accentColor }
    var brandOnPrimary: Color { onAccentColor }

    // MARK: - Button Colors

    var buttonPrimary: Color { accentColor }
    var buttonPrimaryText: Color { onAccentColor }
    var buttonSecondary: Color { tokens.neutralTone20 }
    var buttonSecondaryText: Color { tokens.neutralOnSurface }
    var buttonDisabled: Color { tokens.neutralTone40 }
    var buttonDisabledText: Color { isDark ? tokens.neutralTone80 : tokens.neutralTone60 }

    // MARK: - Chat Bubble Colors

    var chatBubbleUser: Color { accentColor }
    var chatBubbleUserText: Color { onAccentColor }
    var chatBubbleAssistant: Color { isDark ? tokens.neutralTone20 : tokens.neutralTone00 }
    var chatBubbleAssistantText: Color { tokens.neutralOnSurface }
    var chatBubbleAssistantBorder: Color { isDark ? tokens.neutralTone40 : tokens.neutralTone20 }

    // MARK: - Input Colors

    var inputBackground: Color {
        if useTintedBackgrounds {
            return isDark
                ? Color(hex: 0x1E1E1E).blend(with: accentColor, amount: 0.04)
                : Color(hex: 0xF8F8F8).blend(with: accentColor, amount: 0.02)
        }
        return isDark ? Color(hex: 0x1E1E1E) : Color(hex: 0xF8F8F8)
    }

    var inputBorder: Color { isDark ? Color(hex: 0x3A3A3A) : Color(hex: 0xE0E0E0) }
    var inputBorderFocused: Color { accentColor.opacity(0.6) }
    var inputText: Color { tokens.neutralOnSurface }
    var inputPlaceholder: Color { tokens.neutralTone60 }

    // MARK: - Status Colors

    var success: Color { tokens.statusSuccess60 }
    var successBackground: Color {
        tokens.statusSuccess60.opacity(isDark ? 0.24 : 0.12)
    }
    var warning: Color { tokens.statusWarning60 }
    var warningBackground: Color {
        tokens.statusWarning60.opacity(isDark ? 0.24 : 0.12)
    }
    var error: Color { tokens.statusError60 }
    var errorBackground: Color {
        tokens.statusError60.opacity(isDark ? 0.24 : 0.12)
    }
    var info: Color { tokens.statusInfo60 }
    var infoBackground: Color {
        tokens.statusInfo60.opacity(isDark ? 0.24 : 0.12)
    }

    // MARK: - Navigation Colors

    var navigationBackground: Color {
        if useTintedBackgrounds {
            return isDark
                ? Color(hex: 0x0A0A0A).blend(with: accentColor, amount: 0.03)
                : Color(hex: 0xFAFAFA).blend(with: accentColor, amount: 0.02)
        }
        return isDark ? tokens.neutralTone10 : tokens.neutralTone00
    }

    var navigationSelected: Color { accentColor }
    var navigationUnselected: Color { isDark ? tokens.neutralTone80 : tokens.neutralTone60 }

    // MARK: - Divider

    var divider: Color { isDark ? tokens.neutralTone40 : tokens.neutralTone20 }

    // MARK: - Shimmer / Loading

    var shimmerBase: Color { isDark ? Color(hex: 0x1E1E1E) : Color(hex: 0xF0F0F0) }
    var shimmerHighlight: Color { isDark ? Color(hex: 0x2A2A2A) : Color(hex: 0xFAFAFA) }

    // MARK: - Code

    var codeBackground: Color { tokens.codeBackground }
    var codeBorder: Color { tokens.codeBorder }
    var codeText: Color { tokens.codeText }
    var codeAccent: Color { accentColor }

    // MARK: - Sidebar

    var sidebarBackground: Color {
        if useTintedBackgrounds {
            return isDark
                ? Color(hex: 0x080808).blend(with: accentColor, amount: 0.03)
                : Color(hex: 0xFAFAFA).blend(with: accentColor, amount: 0.02)
        }
        return isDark ? Color(hex: 0x0A0A0A) : Color(hex: 0xFAFAFA)
    }

    var sidebarBorder: Color { isDark ? Color(hex: 0x282828) : Color(hex: 0xE5E5E5) }
}

// MARK: - Color Blending

extension Color {
    /// Blends this color with another color by a given amount (0.0 – 1.0).
    func blend(with other: Color, amount: Double) -> Color {
        let clamped = min(max(amount, 0), 1)
        // Use UIColor to resolve components
        let base = UIColor(self)
        let target = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        base.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        target.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(
            red: r1 + (r2 - r1) * clamped,
            green: g1 + (g2 - g1) * clamped,
            blue: b1 + (b2 - b1) * clamped
        )
    }
}

// MARK: - Environment Key

private struct ThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppTheme()
}

extension EnvironmentValues {
    /// The current app theme, providing semantic colors and design tokens.
    var theme: AppTheme {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}

// MARK: - Theme Modifier

/// View modifier that injects the appropriate ``AppTheme`` based on
/// the current `colorScheme` and the user's appearance preferences.
struct ThemedViewModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var appearanceManager: AppearanceManager?

    func body(content: Content) -> some View {
        let accent = appearanceManager?.accentColorPreset ?? .blue
        let pureBlack = appearanceManager?.usePureBlackDark ?? false
        let tinted = appearanceManager?.useTintedBackgrounds ?? false
        let custom: Color? = (appearanceManager?.useCustomColor == true) ? appearanceManager?.customColor : nil

        let theme = AppTheme(
            colorScheme: colorScheme,
            accent: accent,
            usePureBlack: pureBlack,
            useTintedBackgrounds: tinted,
            customColor: custom
        )

        let resolvedTint = custom ?? accent.resolved(for: colorScheme)

        content
            .environment(\.theme, theme)
            .tint(resolvedTint)
    }
}

extension View {
    /// Applies the Conduit design system theme to this view hierarchy.
    func themed(with manager: AppearanceManager? = nil) -> some View {
        modifier(ThemedViewModifier(appearanceManager: manager))
    }
}