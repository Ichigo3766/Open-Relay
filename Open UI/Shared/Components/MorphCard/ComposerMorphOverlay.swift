import SwiftUI

// MARK: - Composer Morph Overlay
//
// Rendered by the chat screen on top of everything (not inside the bottom bar), so
// opening the card never changes the bar's height or re-lays out the message list.
//
// The card starts as an exact copy of the composer (same frame, corner radius and
// glass), then grows upward into the card. Only the clip shape animates. The
// content is laid out once at full size and rides up with the card's top edge.
// Closing runs the same path in reverse.

struct ComposerMorphOverlayHost: View {
    let state: ComposerMorphState

    var body: some View {
        GeometryReader { proxy in
            if let request = state.request, let anchor = state.composerAnchor {
                ComposerMorphCardView(
                    request: request,
                    composerRect: proxy[anchor],
                    composerCorner: state.composerCornerRadius,
                    containerSize: proxy.size,
                    topInset: proxy.safeAreaInsets.top,
                    handoffTileRect: state.handoffTileAnchor.map { proxy[$0] }
                )
            }
        }
        .allowsHitTesting(state.request != nil)
    }
}

struct ComposerMorphCardView: View {
    let request: ComposerMorphRequest
    let composerRect: CGRect
    let composerCorner: CGFloat
    let containerSize: CGSize
    let topInset: CGFloat
    /// Where a captured photo lands in the composer (nil = no hand-off tile).
    var handoffTileRect: CGRect? = nil
    @Environment(\.theme) var theme
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// 0 = composer shape, 1 = full card.
    @State var progress: CGFloat = 0
    @State var revealed = false

    var isCamera: Bool { request.kind == .camera }

    var targetHeight: CGFloat {
        let available = max(composerRect.height + 120,
                            composerRect.maxY - (topInset + MorphCardMetrics.topBarHeight + 8))
        switch request.kind {
        case .menu:
            return request.menuExpanded ? available : min(available * 0.7, 540)
        case .camera:
            return min(available, composerRect.width * 1.45)
        }
    }

    var body: some View {
        let shape = MorphShape(progress: progress,
                               startHeight: composerRect.height,
                               endHeight: targetHeight,
                               startCorner: composerCorner,
                               endCorner: MorphCardMetrics.cornerRadius)
        // How far the card's top edge still is below its final spot.
        let edgeLag = (1 - progress) * (targetHeight - composerRect.height)

        ZStack(alignment: .topLeading) {
            // Tap outside to close. Barely tinted, so it feels like the same screen.
            Color.black.opacity(0.14 * progress)
                .contentShape(Rectangle())
                .onTapGesture { request.onDismissRequest() }
                .ignoresSafeArea()

            ZStack(alignment: .topLeading) {
                surface(shape)

                request.content
                    .id(request.kind)
                    .opacity(isCamera ? Double(max(0, min(1, progress * 1.6 - 0.5))) : 1)
                    .frame(width: composerRect.width, height: targetHeight)
                    .offset(y: edgeLag)
                    .environment(\.morphContentRevealed, revealed)

                if request.kind == .menu && !request.menuExpanded {
                    closeButton
                        .padding(.leading, Spacing.md)
                        .padding(.top, Spacing.sm)
                        .offset(y: edgeLag)
                }
            }
            .frame(width: composerRect.width, height: targetHeight)
            .clipShape(shape)
            .contentShape(shape)
            .shadow(color: .black.opacity((theme.isDark ? 0.4 : 0.16) * progress), radius: 22, y: 8)
            .offset(x: composerRect.minX, y: composerRect.maxY - targetHeight)

            // Captured photo: starts as the frozen viewfinder frame and shrinks with
            // the card into its tile in the composer.
            if let photo = request.handoffImage {
                flyingPhoto(photo)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
        .onAppear(perform: open)
        .onChange(of: request.isClosing) { _, closing in
            if closing { close() }
        }
    }
}
