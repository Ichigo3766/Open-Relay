import SwiftUI
import UIKit

// MARK: - Composer Morph Card
//
// The composer grows in place into a rounded card (the "+" menu or the camera)
// and shrinks back into the composer when closed. These are the shared pieces
// used by the menu, the camera card and the recent-photo fan.

/// What the composer is currently morphed into.
enum ComposerMorph: Equatable {
    case menu
    case camera
}

enum MorphCardMetrics {
    /// Spring used for growing the card and changing its size.
    static let spring: Animation = .spring(response: 0.44, dampingFraction: 0.84)
    /// Critically damped spring for shrinking back into the composer (no overshoot,
    /// so the hand-off to the real composer is seamless).
    static let closeSpring: Animation = .spring(response: 0.34, dampingFraction: 1)
    /// Faster spring for small control changes inside the card.
    static let controlSpring: Animation = .spring(response: 0.3, dampingFraction: 0.78)
    static let cornerRadius: CGFloat = 30
    /// Height of the chat's custom top bar the card must stay below.
    static let topBarHeight: CGFloat = 64

    /// The app's active key window (falls back to the main screen bounds).
    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }
    }

    static var windowHeight: CGFloat {
        keyWindow?.bounds.height ?? UIScreen.main.bounds.height
    }
}

// MARK: - Morph Shape

/// A rounded rectangle pinned to the bottom of its frame whose height and corner
/// radius interpolate from the composer's to the card's. Animatable, so the card
/// grows smoothly without re-laying out its contents every frame.
struct MorphShape: Shape {
    var progress: CGFloat
    var startHeight: CGFloat
    var endHeight: CGFloat
    var startCorner: CGFloat
    var endCorner: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, endHeight) }
        set { progress = newValue.first; endHeight = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let p = max(0, progress)
        let height = startHeight + (endHeight - startHeight) * p
        let corner = startCorner + (endCorner - startCorner) * min(1, p)
        let shapeRect = CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
        return RoundedRectangle(cornerRadius: min(corner, height / 2), style: .continuous).path(in: shapeRect)
    }
}

extension View {
    /// The composer's glass material, applied in any shape (iOS 26 Liquid Glass,
    /// frosted material earlier) — so the card is the same surface as the composer.
    @ViewBuilder
    func morphGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

// MARK: - Staggered Row Reveal

extension EnvironmentValues {
    /// False while the morph card is still growing / shrinking: rows wait just below
    /// their spot, faded out, then deal in one after another once it flips to true.
    @Entry var morphContentRevealed: Bool = true
}

struct MorphRowReveal: ViewModifier {
    let isRevealed: Bool
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isRevealed ? 1 : 0)
            .offset(y: isRevealed || reduceMotion ? 0 : 14)
            .animation(
                isRevealed
                    ? .spring(response: 0.4, dampingFraction: 0.86).delay(0.07 + Double(index) * 0.035)
                    : .easeOut(duration: 0.1),
                value: isRevealed
            )
    }
}

// MARK: - Composer → Overlay Hand-off

/// What the composer asks the chat screen to draw on top of everything.
struct ComposerMorphRequest {
    var kind: ComposerMorph
    var menuExpanded: Bool
    var isClosing: Bool
    var content: AnyView
    var onOpened: () -> Void
    var onClosed: () -> Void
    var onDismissRequest: () -> Void
    /// Captured photo that flies from the viewfinder into its composer tile
    /// while the card shrinks back (nil = plain close).
    var handoffImage: UIImage? = nil
}

/// A captured photo on its way from the camera card into the composer.
struct ComposerMorphHandoff {
    let attachmentId: UUID
    let image: UIImage
}

/// Composer geometry + the current card request, carried up from the composer
/// (inside the bottom bar) to the chat screen, which renders the card as an
/// overlay — so opening it never changes the bottom bar's height or re-lays out
/// the message list.
struct ComposerMorphState {
    var composerAnchor: Anchor<CGRect>?
    var composerCornerRadius: CGFloat = 22
    var plusAnchor: Anchor<CGRect>?
    /// Frame of the (hidden) attachment tile the captured photo lands in.
    var handoffTileAnchor: Anchor<CGRect>?
    var request: ComposerMorphRequest?
}

struct ComposerMorphKey: PreferenceKey {
    static let defaultValue = ComposerMorphState()

    static func reduce(value: inout ComposerMorphState, nextValue: () -> ComposerMorphState) {
        let next = nextValue()
        if let anchor = next.composerAnchor {
            value.composerAnchor = anchor
            value.composerCornerRadius = next.composerCornerRadius
        }
        if let plus = next.plusAnchor { value.plusAnchor = plus }
        if let tile = next.handoffTileAnchor { value.handoffTileAnchor = tile }
        if let request = next.request { value.request = request }
    }
}

// MARK: - Press Effect

/// The one press effect used by every tappable control inside the morph card:
/// a quick springy shrink while the finger is down.
struct MorphPressStyle: ButtonStyle {
    var scale: CGFloat = 0.93

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.68), value: configuration.isPressed)
    }
}

// MARK: - In-Card Back Action

/// "Back" action for sub-pages inside the morph card. Compares equal so storing it
/// in the environment doesn't invalidate every dependent on each update.
struct MorphCardBackAction: Equatable {
    let action: () -> Void
    func callAsFunction() { action() }
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
    /// Set by the morph card for its sub-pages: when present, "Back" buttons
    /// slide back to the card's main page instead of dismissing a presentation.
    @Entry var morphCardBack: MorphCardBackAction? = nil
}

// MARK: - Round Glass Control

/// Circular translucent control used on top of the camera viewfinder.
struct MorphRoundControl: View {
    let systemImage: String
    var size: CGFloat = 44
    var isActive: Bool = false
    var accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.play(.light)
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(isActive ? Color.black : Color.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .background {
                    Circle()
                        .fill(isActive ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial))
                        .environment(\.colorScheme, .dark)
                }
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(MorphPressStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}
