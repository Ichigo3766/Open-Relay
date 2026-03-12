import SwiftUI

// MARK: - Common View Styling Extensions

extension View {

    // MARK: Card Style

    /// Applies the standard Conduit card appearance.
    func cardStyle() -> some View {
        modifier(CardStyleModifier())
    }

    /// Applies a subtle card style without a border.
    func subtleCardStyle() -> some View {
        modifier(SubtleCardStyleModifier())
    }

    // MARK: Pill / Badge

    /// Shapes the view as a pill (fully rounded).
    func pillStyle(
        background: Color? = nil,
        foreground: Color? = nil
    ) -> some View {
        modifier(PillStyleModifier(bg: background, fg: foreground))
    }

    // MARK: Shadow

    /// Applies a small shadow using the theme tokens.
    func shadowSm() -> some View { modifier(SmallShadowModifier()) }

    /// Applies a medium shadow.
    func shadowMd() -> some View { modifier(MediumShadowModifier()) }

    /// Applies a large shadow.
    func shadowLg() -> some View { modifier(LargeShadowModifier()) }

    // MARK: Shimmer

    /// Adds a shimmer/skeleton loading effect.
    func shimmer(isActive: Bool = true) -> some View {
        modifier(ShimmerModifier(isActive: isActive))
    }

    // MARK: Haptic Feedback

    /// Triggers a light haptic on tap.
    func hapticTap(style: Haptics.Style = .light) -> some View {
        self.simultaneousGesture(
            TapGesture().onEnded { _ in
                Haptics.play(style)
            }
        )
    }
}

// MARK: - Card Modifier

private struct CardStyleModifier: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .strokeBorder(theme.cardBorder, lineWidth: 1)
            )
    }
}

private struct SubtleCardStyleModifier: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .background(theme.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
    }
}

// MARK: - Pill Modifier

private struct PillStyleModifier: ViewModifier {
    let bg: Color?
    let fg: Color?
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .font(AppTypography.labelSmallFont)
            .foregroundStyle(fg ?? theme.textPrimary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(bg ?? theme.surfaceContainer)
            .clipShape(Capsule())
    }
}

// MARK: - Shadow Modifiers

private struct SmallShadowModifier: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .shadow(
                color: theme.isDark ? .clear : .black.opacity(0.06),
                radius: 4,
                x: 0,
                y: 2
            )
    }
}

private struct MediumShadowModifier: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .shadow(
                color: theme.isDark ? .clear : .black.opacity(0.08),
                radius: 8,
                x: 0,
                y: 4
            )
    }
}

private struct LargeShadowModifier: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .shadow(
                color: theme.isDark ? .clear : .black.opacity(0.12),
                radius: 16,
                x: 0,
                y: 8
            )
    }
}

// MARK: - Shimmer Effect

private struct ShimmerModifier: ViewModifier {
    let isActive: Bool
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        if isActive {
            content
                .overlay(shimmerOverlay)
                .onAppear {
                    withAnimation(
                        .linear(duration: 1.5)
                        .repeatForever(autoreverses: false)
                    ) {
                        phase = 1
                    }
                }
        } else {
            content
        }
    }

    private var shimmerOverlay: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            LinearGradient(
                gradient: Gradient(colors: [
                    .clear,
                    .white.opacity(0.15),
                    .clear,
                ]),
                startPoint: .init(x: phase - 0.5, y: 0.5),
                endPoint: .init(x: phase + 0.5, y: 0.5)
            )
            .frame(width: width)
        }
        .clipped()
    }
}

// MARK: - Conditional Modifier

extension View {
    /// Applies a modifier conditionally.
    @ViewBuilder
    func `if`<Transform: View>(
        _ condition: Bool,
        transform: (Self) -> Transform
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
