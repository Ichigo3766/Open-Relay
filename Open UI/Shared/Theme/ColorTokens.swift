import SwiftUI

// MARK: - Color Tokens

/// Semantic color tokens derived from the Conduit color specification.
///
/// Provides consistent mappings for light and dark modes. Views should
/// prefer these tokens over hard-coded color values to ensure theme
/// parity and accessible contrast levels.
struct ColorTokens: Sendable {

    // MARK: Neutral

    let neutralTone00: Color
    let neutralTone10: Color
    let neutralTone20: Color
    let neutralTone40: Color
    let neutralTone60: Color
    let neutralTone80: Color
    let neutralOnSurface: Color

    // MARK: Brand

    let brandTone40: Color
    let brandTone60: Color
    let brandOn60: Color
    let brandTone90: Color
    let brandOn90: Color

    // MARK: Accent

    let accentIndigo60: Color
    let accentOnIndigo60: Color
    let accentTeal60: Color
    let accentGold60: Color

    // MARK: Status

    let statusSuccess60: Color
    let statusOnSuccess60: Color
    let statusWarning60: Color
    let statusOnWarning60: Color
    let statusError60: Color
    let statusOnError60: Color
    let statusInfo60: Color
    let statusOnInfo60: Color

    // MARK: Overlay

    let overlayWeak: Color
    let overlayMedium: Color
    let overlayStrong: Color

    // MARK: Scrim

    let scrimMedium: Color
    let scrimStrong: Color

    // MARK: Code

    let codeBackground: Color
    let codeBorder: Color
    let codeText: Color
    let codeAccent: Color
}

// MARK: - Light / Dark Factories

extension ColorTokens {

    /// Light-mode token set matching the Conduit theme.
    static let light = ColorTokens(
        neutralTone00: Color(hex: 0xFFFFFF),
        neutralTone10: Color(hex: 0xFAFAFA),
        neutralTone20: Color(hex: 0xFFFFFF),
        neutralTone40: Color(hex: 0xF5F5F5),
        neutralTone60: Color(hex: 0x737373),
        neutralTone80: Color(hex: 0x171717),
        neutralOnSurface: Color(hex: 0x0A0A0A),
        brandTone40: Color(hex: 0x404040),
        brandTone60: Color(hex: 0x171717),
        brandOn60: Color(hex: 0xFAFAFA),
        brandTone90: Color(hex: 0xF5F5F5),
        brandOn90: Color(hex: 0x171717),
        accentIndigo60: Color(hex: 0xF5F5F5),
        accentOnIndigo60: Color(hex: 0x171717),
        accentTeal60: Color(hex: 0xF5F5F5),
        accentGold60: Color(hex: 0xF5F5F5),
        statusSuccess60: Color(hex: 0x00E6C7),
        statusOnSuccess60: Color(hex: 0x09090B),
        statusWarning60: Color(hex: 0xF97316),
        statusOnWarning60: Color(hex: 0x09090B),
        statusError60: Color(hex: 0xE7000B),
        statusOnError60: Color(hex: 0xFAFAFA),
        statusInfo60: Color(hex: 0x2563EB),
        statusOnInfo60: Color(hex: 0xFAFAFA),
        overlayWeak: Color(hex: 0x0A0A0A, opacity: 0.08),
        overlayMedium: Color(hex: 0x0A0A0A, opacity: 0.16),
        overlayStrong: Color(hex: 0x0A0A0A, opacity: 0.32),
        scrimMedium: Color(hex: 0x000000, opacity: 0.2),
        scrimStrong: Color(hex: 0x000000, opacity: 0.32),
        codeBackground: Color(hex: 0xFAFAFA),
        codeBorder: Color(hex: 0xE5E5E5),
        codeText: Color(hex: 0x0A0A0A),
        codeAccent: Color(hex: 0x171717)
    )

    /// Dark-mode token set matching the Conduit theme.
    static let dark = ColorTokens(
        neutralTone00: Color(hex: 0x0A0A0A),
        neutralTone10: Color(hex: 0x121212),
        neutralTone20: Color(hex: 0x171717),
        neutralTone40: Color(hex: 0x262626),
        neutralTone60: Color(hex: 0xA1A1AA),
        neutralTone80: Color(hex: 0xFAFAFA),
        neutralOnSurface: Color(hex: 0xFAFAFA),
        brandTone40: Color(hex: 0xA0A0A0),
        brandTone60: Color(hex: 0xE5E5E5),
        brandOn60: Color(hex: 0x171717),
        brandTone90: Color(hex: 0x262626),
        brandOn90: Color(hex: 0xE5E5E5),
        accentIndigo60: Color(hex: 0x262626),
        accentOnIndigo60: Color(hex: 0xFAFAFA),
        accentTeal60: Color(hex: 0x404040),
        accentGold60: Color(hex: 0x404040),
        statusSuccess60: Color(hex: 0x00E6C7),
        statusOnSuccess60: Color(hex: 0x09090B),
        statusWarning60: Color(hex: 0xF97316),
        statusOnWarning60: Color(hex: 0x09090B),
        statusError60: Color(hex: 0xFF6467),
        statusOnError60: Color(hex: 0xFAFAFA),
        statusInfo60: Color(hex: 0x2563EB),
        statusOnInfo60: Color(hex: 0xFAFAFA),
        overlayWeak: Color(hex: 0xFAFAFA, opacity: 0.12),
        overlayMedium: Color(hex: 0xFAFAFA, opacity: 0.20),
        overlayStrong: Color(hex: 0xFAFAFA, opacity: 0.36),
        scrimMedium: Color(hex: 0x000000, opacity: 0.5),
        scrimStrong: Color(hex: 0x000000, opacity: 0.6),
        codeBackground: Color(hex: 0x1A1A1A),
        codeBorder: Color(hex: 0x333333),
        codeText: Color(hex: 0xFAFAFA),
        codeAccent: Color(hex: 0xE5E5E5)
    )

    /// Resolves light or dark tokens based on the current color scheme.
    static func resolved(for colorScheme: ColorScheme) -> ColorTokens {
        colorScheme == .dark ? .dark : .light
    }
}

// MARK: - Hex Color Initializer

extension Color {
    /// Creates a `Color` from a 24-bit hex value (e.g., `0xFF6467`).
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }

    /// Creates a `Color` from a 24-bit hex value with a custom opacity.
    init(hex: UInt32, opacity: Double) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
