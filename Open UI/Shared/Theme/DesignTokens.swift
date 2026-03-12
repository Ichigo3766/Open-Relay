import SwiftUI

// MARK: - Spacing

/// Consistent spacing values using an 8-point grid system.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
    static let xxxl: CGFloat = 64

    // Component-specific spacing
    static let buttonPadding: CGFloat = 16
    static let cardPadding: CGFloat = 20
    static let inputPadding: CGFloat = 16
    static let messagePadding: CGFloat = 16
    static let chatBubblePadding: CGFloat = 12
    static let sectionPadding: CGFloat = 24
    static let screenPadding: CGFloat = 16
    static let listGap: CGFloat = 12
    static let sectionGap: CGFloat = 32
}

// MARK: - Corner Radius

/// Consistent corner radius values.
enum CornerRadius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let pill: CGFloat = 999

    // Component-specific
    static let button: CGFloat = 12
    static let card: CGFloat = 16
    static let input: CGFloat = 12
    static let chatBubble: CGFloat = 20
    static let avatar: CGFloat = 50
    static let modal: CGFloat = 20
    static let badge: CGFloat = 20
}

// MARK: - Icon Sizes

/// Consistent icon sizing.
enum IconSize {
    static let xs: CGFloat = 12
    static let sm: CGFloat = 16
    static let md: CGFloat = 20
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
}

// MARK: - Touch Targets

/// Minimum touch target sizes for accessibility compliance (44pt minimum).
enum TouchTarget {
    static let minimum: CGFloat = 44
    static let comfortable: CGFloat = 48
    static let large: CGFloat = 56
}

// MARK: - Animation Constants

/// Consistent animation durations.
enum AnimDuration {
    static let instant: Double = 0.1
    static let fast: Double = 0.2
    static let medium: Double = 0.3
    static let slow: Double = 0.5
    static let slower: Double = 0.8
    static let messageAppear: Double = 0.35
}

// MARK: - Opacity Constants

/// Common opacity values.
enum OpacityLevel {
    static let subtle: Double = 0.1
    static let light: Double = 0.3
    static let medium: Double = 0.5
    static let strong: Double = 0.7
    static let intense: Double = 0.9
    static let disabled: Double = 0.38
    static let hover: Double = 0.08
    static let pressed: Double = 0.2
}
