import SwiftUI

/// Manages user appearance preferences (color scheme, accent color, theme) with persistence.
@Observable
final class AppearanceManager {

    // MARK: - Color Scheme Mode

    /// The user's preferred color scheme mode.
    enum ColorSchemeMode: String, CaseIterable, Codable, Sendable {
        case system = "system"
        case light = "light"
        case dark = "dark"

        var displayName: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var icon: String {
            switch self {
            case .system: return "circle.lefthalf.filled"
            case .light: return "sun.max.fill"
            case .dark: return "moon.fill"
            }
        }
    }

    // MARK: - Accent Color

    /// Available accent color presets with rich color palettes for light & dark modes.
    enum AccentColorPreset: String, CaseIterable, Codable, Sendable {
        case monochrome = "monochrome"
        case blue = "blue"
        case indigo = "indigo"
        case purple = "purple"
        case violet = "violet"
        case pink = "pink"
        case red = "red"
        case orange = "orange"
        case amber = "amber"
        case green = "green"
        case teal = "teal"
        case cyan = "cyan"

        var displayName: String {
            rawValue.capitalized
        }

        /// The primary accent color for display in the picker.
        var color: Color {
            switch self {
            case .monochrome: return Color(hex: 0x737373)
            case .blue:       return Color(hex: 0x3B82F6)
            case .indigo:     return Color(hex: 0x6366F1)
            case .purple:     return Color(hex: 0x8B5CF6)
            case .violet:     return Color(hex: 0xA855F7)
            case .pink:       return Color(hex: 0xEC4899)
            case .red:        return Color(hex: 0xEF4444)
            case .orange:     return Color(hex: 0xF97316)
            case .amber:      return Color(hex: 0xF59E0B)
            case .green:      return Color(hex: 0x22C55E)
            case .teal:       return Color(hex: 0x14B8A6)
            case .cyan:       return Color(hex: 0x06B6D4)
            }
        }

        /// Light-mode accent color (slightly more saturated/darker for contrast on white).
        var lightColor: Color {
            switch self {
            case .monochrome: return Color(hex: 0x171717)
            case .blue:       return Color(hex: 0x2563EB)
            case .indigo:     return Color(hex: 0x4F46E5)
            case .purple:     return Color(hex: 0x7C3AED)
            case .violet:     return Color(hex: 0x9333EA)
            case .pink:       return Color(hex: 0xDB2777)
            case .red:        return Color(hex: 0xDC2626)
            case .orange:     return Color(hex: 0xEA580C)
            case .amber:      return Color(hex: 0xD97706)
            case .green:      return Color(hex: 0x16A34A)
            case .teal:       return Color(hex: 0x0D9488)
            case .cyan:       return Color(hex: 0x0891B2)
            }
        }

        /// Dark-mode accent color (slightly brighter for contrast on dark backgrounds).
        var darkColor: Color {
            switch self {
            case .monochrome: return Color(hex: 0xE5E5E5)
            case .blue:       return Color(hex: 0x60A5FA)
            case .indigo:     return Color(hex: 0x818CF8)
            case .purple:     return Color(hex: 0xA78BFA)
            case .violet:     return Color(hex: 0xC084FC)
            case .pink:       return Color(hex: 0xF472B6)
            case .red:        return Color(hex: 0xF87171)
            case .orange:     return Color(hex: 0xFB923C)
            case .amber:      return Color(hex: 0xFBBF24)
            case .green:      return Color(hex: 0x4ADE80)
            case .teal:       return Color(hex: 0x2DD4BF)
            case .cyan:       return Color(hex: 0x22D3EE)
            }
        }

        /// The text color on top of the accent (light mode).
        var lightOnAccent: Color {
            switch self {
            case .monochrome: return Color(hex: 0xFAFAFA)
            case .amber:      return Color(hex: 0x171717)
            default:          return .white
            }
        }

        /// The text color on top of the accent (dark mode).
        /// In dark mode, accent colors are bright/saturated — white text
        /// provides the best contrast and matches iMessage / ChatGPT style.
        var darkOnAccent: Color {
            switch self {
            case .monochrome: return Color(hex: 0x171717)
            case .amber:      return Color(hex: 0x171717)
            default:          return .white
            }
        }

        /// A subtle tinted background for light mode.
        var lightTintedBackground: Color {
            lightColor.opacity(0.08)
        }

        /// A subtle tinted background for dark mode.
        var darkTintedBackground: Color {
            darkColor.opacity(0.12)
        }

        /// Icon for the color preset (SF Symbol).
        var icon: String {
            switch self {
            case .monochrome: return "circle.lefthalf.filled"
            case .blue:       return "drop.fill"
            case .indigo:     return "sparkles"
            case .purple:     return "wand.and.stars"
            case .violet:     return "aqi.medium"
            case .pink:       return "heart.fill"
            case .red:        return "flame.fill"
            case .orange:     return "sun.max.fill"
            case .amber:      return "bolt.fill"
            case .green:      return "leaf.fill"
            case .teal:       return "wave.3.right"
            case .cyan:       return "drop.circle.fill"
            }
        }

        /// Resolve the accent color for a given color scheme.
        func resolved(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? darkColor : lightColor
        }

        /// Resolve the on-accent color for a given color scheme.
        func resolvedOnAccent(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? darkOnAccent : lightOnAccent
        }
    }

    // MARK: - State

    var colorSchemeMode: ColorSchemeMode {
        didSet { save() }
    }

    var accentColorPreset: AccentColorPreset {
        didSet { save() }
    }

    var useDynamicType: Bool {
        didSet { save() }
    }

    var reduceMotion: Bool {
        didSet { save() }
    }

    var usePureBlackDark: Bool {
        didSet { save() }
    }

    var useTintedBackgrounds: Bool {
        didSet { save() }
    }

    /// Whether the user is using a custom color instead of a preset.
    var useCustomColor: Bool {
        didSet { save() }
    }

    /// The custom accent color components (hue, saturation, brightness) stored as a string "h,s,b".
    var customColorHSB: String {
        didSet { save() }
    }

    /// The resolved custom color from the stored HSB string.
    var customColor: Color {
        let parts = customColorHSB.components(separatedBy: ",").compactMap { Double($0) }
        guard parts.count == 3 else { return .blue }
        return Color(hue: parts[0], saturation: parts[1], brightness: parts[2])
    }

    /// Sets the custom color from a SwiftUI Color value.
    func setCustomColor(_ color: Color) {
        let uiColor = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        customColorHSB = "\(h),\(s),\(b)"
        useCustomColor = true
    }

    /// The resolved `ColorScheme?` for `preferredColorScheme(_:)`.
    /// Returns `nil` for system mode (no override).
    var resolvedColorScheme: ColorScheme? {
        switch colorSchemeMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    // MARK: - Persistence

    private static let modeKey = "openui.appearance.mode"
    private static let accentKey = "openui.appearance.accent"
    private static let dynamicTypeKey = "openui.appearance.dynamicType"
    private static let reduceMotionKey = "openui.appearance.reduceMotion"
    private static let pureBlackKey = "openui.appearance.pureBlack"
    private static let tintedBgKey = "openui.appearance.tintedBg"
    private static let useCustomColorKey = "openui.appearance.useCustomColor"
    private static let customColorHSBKey = "openui.appearance.customColorHSB"

    init() {
        let storedMode = UserDefaults.standard.string(forKey: Self.modeKey) ?? "system"
        self.colorSchemeMode = ColorSchemeMode(rawValue: storedMode) ?? .system

        let storedAccent = UserDefaults.standard.string(forKey: Self.accentKey) ?? "blue"
        self.accentColorPreset = AccentColorPreset(rawValue: storedAccent) ?? .blue

        self.useDynamicType = UserDefaults.standard.object(forKey: Self.dynamicTypeKey) as? Bool ?? true
        self.reduceMotion = UserDefaults.standard.object(forKey: Self.reduceMotionKey) as? Bool ?? false
        self.usePureBlackDark = UserDefaults.standard.object(forKey: Self.pureBlackKey) as? Bool ?? false
        self.useTintedBackgrounds = UserDefaults.standard.object(forKey: Self.tintedBgKey) as? Bool ?? false
        self.useCustomColor = UserDefaults.standard.object(forKey: Self.useCustomColorKey) as? Bool ?? false
        self.customColorHSB = UserDefaults.standard.string(forKey: Self.customColorHSBKey) ?? "0.6,0.8,0.9"
    }

    private func save() {
        UserDefaults.standard.set(colorSchemeMode.rawValue, forKey: Self.modeKey)
        UserDefaults.standard.set(accentColorPreset.rawValue, forKey: Self.accentKey)
        UserDefaults.standard.set(useDynamicType, forKey: Self.dynamicTypeKey)
        UserDefaults.standard.set(reduceMotion, forKey: Self.reduceMotionKey)
        UserDefaults.standard.set(usePureBlackDark, forKey: Self.pureBlackKey)
        UserDefaults.standard.set(useTintedBackgrounds, forKey: Self.tintedBgKey)
        UserDefaults.standard.set(useCustomColor, forKey: Self.useCustomColorKey)
        UserDefaults.standard.set(customColorHSB, forKey: Self.customColorHSBKey)
    }
}