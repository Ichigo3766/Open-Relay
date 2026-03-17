import SwiftUI

// MARK: - Micro-Interaction Animations

/// Reusable animation presets for consistent, polished micro-interactions.
///
/// Provides named springs, easing curves, and composable transitions
/// following iOS Human Interface Guidelines.
enum MicroAnimation {

    // MARK: - Named Springs

    /// A responsive spring for button presses and quick feedback.
    static let snappy: Animation = .spring(
        response: 0.3,
        dampingFraction: 0.7,
        blendDuration: 0
    )

    /// A gentle spring for view transitions.
    static let gentle: Animation = .spring(
        response: 0.5,
        dampingFraction: 0.8,
        blendDuration: 0.1
    )

    /// A bouncy spring for playful, attention-grabbing effects.
    static let bouncy: Animation = .spring(
        response: 0.4,
        dampingFraction: 0.6,
        blendDuration: 0
    )

    /// A stiff spring for precise, no-nonsense movements.
    static let stiff: Animation = .spring(
        response: 0.25,
        dampingFraction: 0.9,
        blendDuration: 0
    )

    // MARK: - Named Easing Curves

    /// Standard Material-style easing for most transitions.
    static let standardEasing: Animation = .easeInOut(duration: AnimDuration.medium)

    /// Deceleration curve for elements entering the screen.
    static let enterEasing: Animation = .easeOut(duration: AnimDuration.medium)

    /// Acceleration curve for elements leaving the screen.
    static let exitEasing: Animation = .easeIn(duration: AnimDuration.fast)

    // MARK: - Staggered Animation

    /// Returns an animation delayed by an index-based offset for stagger effects.
    ///
    /// - Parameters:
    ///   - index: The item's position in the sequence.
    ///   - baseDelay: Delay between each item (default 0.05s).
    ///   - animation: The base animation to delay.
    /// - Returns: A delayed animation.
    static func staggered(
        index: Int,
        baseDelay: Double = 0.05,
        animation: Animation = .spring(response: 0.4, dampingFraction: 0.8)
    ) -> Animation {
        animation.delay(Double(index) * baseDelay)
    }
}

// MARK: - Transitions

/// Named transitions for consistent view entrance/exit animations.
extension AnyTransition {

    /// Slide up with opacity fade, ideal for list items appearing.
    static var slideUp: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.95)),
            removal: .opacity
        )
    }

    /// Scale in from center with opacity, ideal for modals and overlays.
    static var scaleIn: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 0.95).combined(with: .opacity)
        )
    }

    /// Slide from trailing edge, ideal for navigation pushes.
    static var slideFromTrailing: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    /// A subtle blur transition for toasts and notifications.
    static var toastTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .top)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.9, anchor: .top)),
            removal: .move(edge: .top)
                .combined(with: .opacity)
        )
    }

    /// Fade with slight vertical offset for chat messages.
    static var messageAppear: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: 8))
                .combined(with: .scale(scale: 0.98, anchor: .bottom)),
            removal: .opacity
        )
    }
}

// MARK: - View Modifiers

/// A press-down scale effect for interactive elements.
///
/// Provides tactile visual feedback when the user presses a button
/// or tappable element.
///
/// Usage:
/// ```swift
/// Button("Tap Me") { }
///     .pressEffect()
/// ```
struct PressEffectModifier: ViewModifier {
    let scale: CGFloat
    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? scale : 1.0)
            .animation(MicroAnimation.snappy, value: isPressed)
            .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                isPressed = pressing
            }, perform: {})
    }
}

/// A success checkmark animation shown after a successful action.
///
/// Usage:
/// ```swift
/// SuccessCheckmark(isVisible: $showSuccess)
/// ```
struct SuccessCheckmark: View {
    @Binding var isVisible: Bool
    @State private var drawProgress: CGFloat = 0
    @State private var circleScale: CGFloat = 0
    @Environment(\.theme) private var theme

    var body: some View {
        if isVisible {
            ZStack {
                // Background circle
                Circle()
                    .fill(theme.success.opacity(0.15))
                    .frame(width: 48, height: 48)
                    .scaleEffect(circleScale)

                // Checkmark
                Image(systemName: "checkmark")
                    .scaledFont(size: 20, weight: .bold)
                    .foregroundStyle(theme.success)
                    .scaleEffect(drawProgress)
                    .opacity(drawProgress)
            }
            .onAppear {
                withAnimation(MicroAnimation.bouncy.delay(0.1)) {
                    circleScale = 1.0
                }
                withAnimation(MicroAnimation.bouncy.delay(0.2)) {
                    drawProgress = 1.0
                }
                // Auto-hide after 1.5 seconds
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(MicroAnimation.exitEasing) {
                        isVisible = false
                        drawProgress = 0
                        circleScale = 0
                    }
                }
            }
            .transition(.scaleIn)
            .accessibilityLabel(Text("Success"))
        }
    }
}

/// An error shake animation that briefly shakes the content horizontally.
///
/// Usage:
/// ```swift
/// TextField("Email", text: $email)
///     .shakeOnError(trigger: errorCount)
/// ```
struct ShakeEffect: GeometryEffect {
    var amount: CGFloat = 8
    var shakesPerUnit = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = amount * sin(animatableData * .pi * CGFloat(shakesPerUnit))
        return ProjectionTransform(
            CGAffineTransform(translationX: translation, y: 0)
        )
    }
}

/// Pulse animation for attention-grabbing elements.
struct PulseModifier: ViewModifier {
    let isActive: Bool
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing && isActive ? 1.05 : 1.0)
            .opacity(isPulsing && isActive ? 0.8 : 1.0)
            .animation(
                isActive
                    ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - Staggered Appear Modifier

/// Drives staggered appearance with a real state change so the animation fires.
private struct StaggeredAppearModifier: ViewModifier {
    let index: Int
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 8)
            .animation(
                MicroAnimation.staggered(index: index),
                value: isVisible
            )
            .onAppear {
                isVisible = true
            }
    }
}

// MARK: - View Extensions

extension View {

    /// Applies a press-down scale effect for tactile feedback.
    ///
    /// - Parameter scale: The scale factor when pressed (default 0.96).
    func pressEffect(scale: CGFloat = 0.96) -> some View {
        modifier(PressEffectModifier(scale: scale))
    }

    /// Applies a shake effect when the trigger value changes.
    ///
    /// - Parameter trigger: An integer that triggers the shake when incremented.
    func shakeOnError(trigger: Int) -> some View {
        modifier(ShakeEffect(animatableData: CGFloat(trigger)))
    }

    /// Applies a pulsing animation when active.
    func pulse(isActive: Bool = true) -> some View {
        modifier(PulseModifier(isActive: isActive))
    }

    /// Applies a staggered appear animation based on index.
    ///
    /// Uses a `@State` flag that transitions from 0→1 on appear,
    /// so the animation actually triggers. Each item delays based
    /// on its index for a cascading entrance effect.
    ///
    /// - Parameter index: The item's position for stagger delay.
    func staggeredAppear(index: Int) -> some View {
        modifier(StaggeredAppearModifier(index: index))
    }
}
