import SwiftUI

// MARK: - Sidebar Page-Card Effects (iOS 26 style)
//
// The chat is a card in front; the sidebar sits behind it. These two modifiers make the
// card read as the main subject and the sidebar as a layer that recedes as the card
// slides back over it. Both are pure functions of `fraction` (0 = closed, 1 = open),
// which already follows the finger and the release spring, so they track drags exactly.

/// The sidebar stays perfectly still and simply fades in as the card slides off it and
/// fades out as the card slides back over it. No scale, no slide, no separate dimming.
struct SidebarRecedeModifier: ViewModifier {
    let fraction: CGFloat
    let width: CGFloat
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.opacity(Double(min(1, max(0, fraction))))
        } else {
            content
        }
    }
}

/// Lifts the card a touch lighter while the sidebar is open, so it stands out against
/// the deeper sidebar behind it (dark mode only; light mode already has a white card).
struct CardLiftModifier: ViewModifier {
    let fraction: CGFloat
    let isEnabled: Bool
    let isDark: Bool

    func body(content: Content) -> some View {
        if isEnabled && isDark {
            content.overlay {
                Color.white.opacity(0.08 * Double(min(1, max(0, fraction))))
                    .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

extension View {
    func sidebarRecede(fraction: CGFloat, width: CGFloat, isEnabled: Bool) -> some View {
        modifier(SidebarRecedeModifier(fraction: fraction, width: width, isEnabled: isEnabled))
    }

    func cardLift(fraction: CGFloat, isEnabled: Bool, isDark: Bool) -> some View {
        modifier(CardLiftModifier(fraction: fraction, isEnabled: isEnabled, isDark: isDark))
    }
}
