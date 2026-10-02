import SwiftUI

// MARK: - Shared Liquid Glass Chrome
//
// Glass building blocks shared by the main chat (ChatDetailView / ChatInputField)
// and channels (ChannelDetailView / ChannelInputField / ThreadDetailSheet).
// iOS 26+: native Liquid Glass. Earlier iOS: frosted material fallbacks.

/// A hidden navigation bar gets native status blur only on iOS 27 with an iOS 27 SDK build.
let hasNativeStatusBlur: Bool = {
    guard #available(iOS 27.0, *),
          let sdk = Bundle.main.object(forInfoDictionaryKey: "DTSDKName") as? String,
          let major = Int(sdk.drop(while: { !$0.isNumber }).prefix(while: \.isNumber))
    else { return false }
    return major >= 27
}()

extension View {
    /// Interactive Liquid Glass on iOS 26+, `fallback` fill on earlier iOS.
    @ViewBuilder
    func chatControlGlass<S: Shape, F: ShapeStyle>(in shape: S, fallback: F) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(fallback, in: shape)
        }
    }

    /// Tinted interactive glass (e.g. the current user's reaction chips).
    @ViewBuilder
    func chatTintedGlass<S: Shape>(in shape: S, tint: Color) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(tint.opacity(0.35)).interactive(), in: shape)
        } else {
            self.background(tint.opacity(0.18), in: shape)
        }
    }

    /// Wraps a chrome bar in a ViewModifier so the host view's (very large)
    /// type appears once per call instead of once per availability/edge branch.
    /// The branching lives in the modifier's own body, which SwiftUI resolves
    /// separately — this keeps large view bodies' types shallow enough that
    /// runtime metadata instantiation does not overflow the main-thread stack.
    func chatChromeBar<Content: View>(edge: VerticalEdge, @ViewBuilder content: () -> Content) -> some View {
        modifier(ChatChromeBarModifier(edge: edge, bar: content()))
    }

    /// Glass/material backdrop behind the status bar when the navigation bar is hidden.
    func statusBarGlassBackdrop(background: Color) -> some View {
        modifier(StatusBarGlassBackdrop(background: background))
    }

    /// Makes a small control easy to hit: the whole circle counts, and the touch area
    /// extends `slop` points past the drawn icon without changing layout.
    func composerHitTarget(slop: CGFloat = 6) -> some View {
        modifier(ComposerHitTarget(slop: slop))
    }
}

struct ChatChromeBarModifier<Bar: View>: ViewModifier {
    let edge: VerticalEdge
    let bar: Bar

    func body(content: Content) -> some View {
        if #available(iOS 27.0, *), hasNativeStatusBlur {
            if edge == .top {
                // Reserve toolbar space without extending the status-area blur behind it.
                content.safeAreaInset(edge: edge, spacing: 0) { bar }
            } else {
                content.safeAreaBar(edge: edge, spacing: 0) { bar }
                    .scrollEdgeEffectHidden(true, for: .bottom)
            }
        } else if #available(iOS 26.0, *) {
            // The custom status-bar glass handles the top blur, so hide the native
            // scroll-edge effect on both edges (avoids a double blur).
            content.safeAreaBar(edge: edge, spacing: 0) { bar }
                .scrollEdgeEffectHidden(true, for: [.top, .bottom])
        } else {
            content.safeAreaInset(edge: edge, spacing: 0) { bar }
        }
    }
}

/// Status-area blur used when the system navigation bar is hidden.
struct StatusBarGlassBackdrop: ViewModifier {
    let background: Color

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geometry in
                Group {
                    if hasNativeStatusBlur {
                        EmptyView()
                    } else if #available(iOS 26.0, *) {
                        Color.clear
                            .glassEffect(.clear, in: Rectangle().inset(by: -geometry.safeAreaInsets.top))
                            .mask(LinearGradient(stops: [
                                .init(color: .black, location: 0.35),
                                .init(color: .clear, location: 1)
                            ], startPoint: .top, endPoint: .bottom))
                    } else {
                        background.opacity(0.8)
                            .background(.ultraThinMaterial)
                            .mask(LinearGradient(stops: [
                                .init(color: .black, location: 0.45),
                                .init(color: .clear, location: 1)
                            ], startPoint: .top, endPoint: .bottom))
                    }
                }
                .frame(height: geometry.safeAreaInsets.top)
                .offset(y: -geometry.safeAreaInsets.top)
            }
            .allowsHitTesting(false)
        }
    }
}

/// Composer surface. iOS 26: interactive Liquid Glass applied directly to the composer,
/// so press-and-hold anywhere on the box gives the native glow/flex response (as in
/// iMessage) while buttons and the text view keep working normally. Earlier iOS keeps
/// the frosted material with border and shadow.
struct ComposerGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let borderColor: Color
    let shadowColor: Color
    let isDark: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content.background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 0.5)
                    }
                    .shadow(color: shadowColor, radius: isDark ? 8 : 14, x: 0, y: isDark ? 2 : 3)
            }
        }
    }
}

struct ComposerHitTarget: ViewModifier {
    var slop: CGFloat = 6

    /// iPad: larger touch slop (≈44pt targets for the 26pt composer icons) plus a
    /// pointer hover effect. iPhone keeps the original slop.
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    func body(content: Content) -> some View {
        let effectiveSlop = isPad ? max(slop, 9) : slop
        content
            .contentShape(Circle())
            .padding(effectiveSlop)
            .contentShape(Rectangle())
            .contentShape(.hoverEffect, Circle())
            .hoverEffect(.highlight, isEnabled: isPad)
            .padding(-effectiveSlop)
    }
}

/// iMessage-style press feedback for the whole composer: while a finger is down
/// anywhere on the box — including over the text view and buttons — the box
/// shrinks slightly. Recognised simultaneously, so typing, cursor placement,
/// selection, button taps and the expand drag all keep working normally.
/// Releases as soon as the finger moves (scroll, select, expand drag).
struct ComposerPressFeedback: ViewModifier {
    let isEnabled: Bool
    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        let moved = abs(value.translation.width) > 8 || abs(value.translation.height) > 8
                        if moved != !isPressed { isPressed = !moved }
                    }
                    .onEnded { _ in isPressed = false }
            )
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isPressed = false }
            }
    }
}

