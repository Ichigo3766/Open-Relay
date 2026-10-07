import SwiftUI

// MARK: - Micro-Interaction Animations

/// Reusable animation presets for consistent, polished micro-interactions.
///
/// Provides named springs, easing curves, and composable transitions
/// following iOS Human Interface Guidelines.
enum MicroAnimation {

    // MARK: - Named Springs

    /// A responsive spring for button presses and quick feedback.
    /// Critically-damped (no overshoot) — overshoot is reserved for momentum-driven gestures.
    static let snappy: Animation = .spring(
        response: 0.3,
        dampingFraction: 0.85,
        blendDuration: 0
    )

    /// A gentle spring for view transitions.
    static let gentle: Animation = .spring(
        response: 0.5,
        dampingFraction: 0.85,
        blendDuration: 0.1
    )

    /// A bouncy spring for playful, attention-grabbing effects.
    /// Only for momentum-driven interactions (flicks, throws, drag releases).
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

    /// Spring for panels/drawers sliding open (slightly under-damped for a physical snap-open feel).
    /// response: 0.32 = fast enough to feel instant, slow enough to track.
    /// dampingFraction: 0.86 = minimal overshoot that communicates physical mass.
    static let panelOpen: Animation = .spring(
        response: 0.32,
        dampingFraction: 0.86,
        blendDuration: 0
    )

    /// Spring for panels/drawers sliding closed (slightly stiffer — dismiss feels decisive).
    static let panelClose: Animation = .spring(
        response: 0.28,
        dampingFraction: 0.9,
        blendDuration: 0
    )

    /// Spring for UI elements that appear/disappear without a gesture (FABs, toasts, overlays).
    /// Critically damped — no bounce since there is no preceding momentum.
    static let presence: Animation = .spring(
        response: 0.35,
        dampingFraction: 1.0,
        blendDuration: 0
    )

    /// Quick ease-out for small toggles, icon swaps and chrome fades.
    static let quick: Animation = .easeOut(duration: 0.15)

    /// The curve the chat uses when it glides to a new message. Use it for any
    /// "move to a new place" animation so the whole app shares one feel.
    static let glide: Animation = .spring(response: 0.5, dampingFraction: 0.85)

    /// Standard crossfade for overlays, banners and screen hand-offs.
    static let fade: Animation = .easeInOut(duration: 0.2)

    /// Spring that continues a drag's speed after the finger lifts.
    ///
    /// - Parameters:
    ///   - velocity: Finger velocity along the axis of travel, in points/second
    ///     (positive = toward the destination).
    ///   - distance: Remaining distance to the destination in points.
    static func release(velocity: CGFloat, distance: CGFloat) -> Animation {
        let travel = max(1, abs(distance))
        // Normalised velocity, clamped so a wild flick can't overshoot visibly.
        let initial = min(30, max(0, velocity / travel))
        return .interpolatingSpring(mass: 1, stiffness: 260, damping: 28, initialVelocity: initial)
    }

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

// MARK: - Button Styles

/// Native-feeling press feedback: a slight shrink and dim that follows the finger
/// and springs back. Built on `ButtonStyle`, so it never interferes with scrolling.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    var dimsTo: Double = 0.75

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? dimsTo : 1)
            .animation(MicroAnimation.stiff, value: configuration.isPressed)
    }
}

/// Press feedback for list rows: a soft highlight, no scaling (so lists don't wobble).
struct SidebarRowButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                    .fill(theme.textPrimary.opacity(configuration.isPressed ? 0.08 : 0))
            )
            .animation(.easeOut(duration: configuration.isPressed ? 0.05 : 0.2), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Shrink-and-dim press feedback.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

extension ButtonStyle where Self == SidebarRowButtonStyle {
    /// Soft highlight press feedback for list rows.
    static var sidebarRow: SidebarRowButtonStyle { SidebarRowButtonStyle() }
}

// MARK: - Entrance Fade

/// Fades a view in and lifts it a few points the first time it appears.
/// Uses only opacity and offset, so it never changes layout or fights scrolling.
private struct EntranceFadeModifier: ViewModifier {
    let rise: CGFloat
    /// Decided once at creation, so the view structure never changes afterwards.
    @State private var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isEnabled: Bool, rise: CGFloat) {
        self.rise = rise
        _shown = State(initialValue: !isEnabled)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : rise)
            .onAppear {
                guard !shown else { return }
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(MicroAnimation.gentle) { shown = true }
                }
            }
    }
}

// MARK: - Expand Chevron

/// One chevron that rotates between collapsed and expanded, instead of
/// swapping between two different symbols.
struct ExpandChevron: View {
    let isExpanded: Bool
    /// Rotation applied when expanded. Defaults to a down-pointing chevron that
    /// turns to point up.
    var expandedDegrees: Double = 180
    var size: CGFloat = 10
    var weight: Font.Weight = .semibold

    var body: some View {
        Image(systemName: "chevron.down")
            .scaledFont(size: size, weight: weight)
            .rotationEffect(.degrees(isExpanded ? expandedDegrees : 0))
            .animation(MicroAnimation.snappy, value: isExpanded)
    }
}

// MARK: - View Extensions

extension View {

    /// Fades the view in with a small upward lift the first time it appears.
    ///
    /// - Parameters:
    ///   - isEnabled: Pass `false` to render with no animation at all.
    ///   - rise: Starting vertical offset in points.
    func entranceFade(isEnabled: Bool = true, rise: CGFloat = 6) -> some View {
        modifier(EntranceFadeModifier(isEnabled: isEnabled, rise: rise))
    }

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
