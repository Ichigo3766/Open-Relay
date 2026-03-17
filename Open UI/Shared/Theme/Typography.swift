import SwiftUI

// MARK: - Typography

/// Typography scale following the Conduit design system.
///
/// Uses the SF system fonts with carefully chosen sizes, weights, and
/// line heights that support Dynamic Type.
///
/// ## Accessibility Scaling
/// All fonts support context-aware scaling via `AccessibilityManager`.
/// Use the `.scaled()` variants or the `.scaledFont()` view modifier
/// to get fonts that respect the user's accessibility preferences.
enum AppTypography {

    // MARK: - Font Definitions (Base Sizes)

    static let displayLargeFont: Font = .system(size: 48, weight: .bold, design: .default)
    static let displayMediumFont: Font = .system(size: 36, weight: .bold, design: .default)
    static let displaySmallFont: Font = .system(size: 32, weight: .bold, design: .default)

    static let headlineLargeFont: Font = .system(size: 28, weight: .bold, design: .default)
    static let headlineMediumFont: Font = .system(size: 24, weight: .semibold, design: .default)
    static let headlineSmallFont: Font = .system(size: 20, weight: .semibold, design: .default)

    static let bodyLargeFont: Font = .system(size: 18, weight: .regular, design: .default)
    static let bodyMediumFont: Font = .system(size: 16, weight: .regular, design: .default)
    static let bodySmallFont: Font = .system(size: 14, weight: .regular, design: .default)

    static let labelLargeFont: Font = .system(size: 16, weight: .medium, design: .default)
    static let labelMediumFont: Font = .system(size: 14, weight: .medium, design: .default)
    static let labelSmallFont: Font = .system(size: 12, weight: .medium, design: .default)

    static let captionFont: Font = .system(size: 12, weight: .medium, design: .default)
    static let codeFont: Font = .system(size: 14, weight: .regular, design: .monospaced)
    static let codeLargeFont: Font = .system(size: 16, weight: .regular, design: .monospaced)

    // MARK: - Scaled Font Factory

    /// Returns a font scaled by the given factor.
    /// Preserves weight and design while adjusting the point size.
    static func scaled(
        baseSize: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        scale: CGFloat
    ) -> Font {
        .system(size: round(baseSize * scale * 10) / 10, weight: weight, design: design)
    }

    /// Returns a system font scaled by the accessibility manager's factor
    /// for the given context.
    static func scaled(
        baseSize: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        context: AccessibilityManager.FontContext,
        manager: AccessibilityManager
    ) -> Font {
        let scale = manager.scale(for: context)
        return .system(size: round(baseSize * scale * 10) / 10, weight: weight, design: design)
    }
}

// MARK: - Text Style View Modifiers

/// Applies display-large typography styling.
struct DisplayLargeStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .font(AppTypography.displayLargeFont)
            .foregroundStyle(theme.textPrimary)
            .tracking(-0.8)
            .lineSpacing(4)
    }
}

/// Applies display-medium typography styling.
struct DisplayMediumStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .font(AppTypography.displayMediumFont)
            .foregroundStyle(theme.textPrimary)
            .tracking(-0.6)
            .lineSpacing(3)
    }
}

/// Applies headline-large typography styling.
struct HeadlineLargeStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .font(AppTypography.headlineLargeFont)
            .foregroundStyle(theme.textPrimary)
            .tracking(-0.4)
            .lineSpacing(2)
    }
}

/// Applies headline-medium typography styling.
struct HeadlineMediumStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .font(AppTypography.headlineMediumFont)
            .foregroundStyle(theme.textPrimary)
            .tracking(-0.2)
    }
}

/// Applies headline-small typography styling.
struct HeadlineSmallStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .font(AppTypography.headlineSmallFont)
            .foregroundStyle(theme.textPrimary)
    }
}

/// Applies body-large typography styling.
struct BodyLargeStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .font(AppTypography.bodyLargeFont)
            .foregroundStyle(theme.textPrimary)
            .lineSpacing(4)
    }
}

/// Applies body-medium typography styling (default body text).
struct BodyMediumStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .font(AppTypography.bodyMediumFont)
            .foregroundStyle(theme.textPrimary)
            .lineSpacing(3)
    }
}

/// Applies body-small typography styling.
struct BodySmallStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .font(AppTypography.bodySmallFont)
            .foregroundStyle(theme.textSecondary)
            .lineSpacing(2)
    }
}

/// Applies label typography styling.
struct LabelStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .font(AppTypography.labelMediumFont)
            .foregroundStyle(theme.textSecondary)
    }
}

/// Applies caption typography styling.
struct CaptionStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .font(AppTypography.captionFont)
            .foregroundStyle(theme.textTertiary)
            .tracking(0.5)
    }
}

/// Applies monospace code typography styling.
struct CodeStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .font(AppTypography.codeFont)
            .foregroundStyle(theme.codeText)
            .lineSpacing(2)
    }
}

// MARK: - View Extensions (Original — Unscaled)

extension View {
    func displayLargeStyle() -> some View { modifier(DisplayLargeStyle()) }
    func displayMediumStyle() -> some View { modifier(DisplayMediumStyle()) }
    func headlineLargeStyle() -> some View { modifier(HeadlineLargeStyle()) }
    func headlineMediumStyle() -> some View { modifier(HeadlineMediumStyle()) }
    func headlineSmallStyle() -> some View { modifier(HeadlineSmallStyle()) }
    func bodyLargeStyle() -> some View { modifier(BodyLargeStyle()) }
    func bodyMediumStyle() -> some View { modifier(BodyMediumStyle()) }
    func bodySmallStyle() -> some View { modifier(BodySmallStyle()) }
    func labelStyle() -> some View { modifier(LabelStyle()) }
    func captionTextStyle() -> some View { modifier(CaptionStyle()) }
    func codeStyle() -> some View { modifier(CodeStyle()) }
}

// MARK: - Scaled Font View Modifier

/// A view modifier that applies a scaled font based on the user's
/// accessibility preferences. Reads the ``AccessibilityManager``
/// from the environment and applies the appropriate scale factor.
struct ScaledFontModifier: ViewModifier {
    let baseSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let context: AccessibilityManager.FontContext

    @Environment(\.accessibilityScale) private var accessibilityScale

    func body(content: Content) -> some View {
        let scale = accessibilityScale.scale(for: context)
        content.font(.system(
            size: round(baseSize * scale * 10) / 10,
            weight: weight,
            design: design
        ))
    }
}

/// A view modifier that scales an icon's font size.
struct ScaledIconModifier: ViewModifier {
    let baseSize: CGFloat
    let weight: Font.Weight

    @Environment(\.accessibilityScale) private var accessibilityScale

    func body(content: Content) -> some View {
        let scale = accessibilityScale.uiScale
        content.font(.system(
            size: round(baseSize * scale * 10) / 10,
            weight: weight
        ))
    }
}

// MARK: - View Extensions (Scaled)

extension View {
    /// Applies a scaled font that respects accessibility preferences.
    ///
    /// ```swift
    /// Text("Hello")
    ///     .scaledFont(size: 16, weight: .medium, context: .content)
    /// ```
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        context: AccessibilityManager.FontContext = .ui
    ) -> some View {
        modifier(ScaledFontModifier(
            baseSize: size,
            weight: weight,
            design: design,
            context: context
        ))
    }

    /// Applies a scaled icon font that respects the UI scale.
    func scaledIcon(size: CGFloat, weight: Font.Weight = .medium) -> some View {
        modifier(ScaledIconModifier(baseSize: size, weight: weight))
    }
}

// MARK: - CGFloat Scaling Extension

extension CGFloat {
    /// Returns this value scaled by the UI scale factor from the accessibility manager.
    func scaled(by manager: AccessibilityManager) -> CGFloat {
        self * manager.uiScale
    }
}

// MARK: - Accessibility Scale Environment Key

/// Environment key to propagate the ``AccessibilityManager`` down the view tree.
private struct AccessibilityScaleEnvironmentKey: EnvironmentKey {
    static let defaultValue = AccessibilityManager()
}

extension EnvironmentValues {
    /// The current accessibility scaling manager.
    var accessibilityScale: AccessibilityManager {
        get { self[AccessibilityScaleEnvironmentKey.self] }
        set { self[AccessibilityScaleEnvironmentKey.self] = newValue }
    }
}
