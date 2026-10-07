import SwiftUI

// MARK: - Model Picker Card
//
// Reuses the + card's springs, glass, tap-outside dismissal and staggered row reveal.

struct ModelPickerCard: View {
    let buttonRect: CGRect
    let containerSize: CGSize
    let keyboardHeight: CGFloat
    /// The button's label for a given chevron rotation in degrees (0 = down, 180 = up).
    let label: (Double) -> AnyView
    let models: [AIModel]
    let selectedModelId: String?
    let serverBaseURL: String
    let authToken: String?
    let isAdmin: Bool
    let pinnedModelIds: [String]
    /// Runs after the card has fully closed (the editor drop starts from here).
    let onEdit: ((AIModel) -> Void)?
    let onTogglePin: ((String) -> Void)?
    let onSelect: (AIModel) -> Void
    let onClosed: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0 = the button, 1 = the full card.
    @State private var progress: CGFloat = 0
    @State private var revealed = false
    @State private var closing = false
    @State private var searching = false

    private var layout: DropCardLayout { DropCardLayout(buttonRect: buttonRect, containerSize: containerSize) }
    private var targetHeight: CGFloat { layout.height(searching: searching, keyboardHeight: keyboardHeight) }

    private var shape: DropCardShape {
        DropCardShape(progress: progress, endHeight: targetHeight, start: buttonRect,
                      endX: layout.x, endWidth: layout.width, startCorner: 12, endCorner: 28)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Tap outside to close; barely tinted so it still feels like the same screen.
            Color.black.opacity(0.16 * progress)
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .ignoresSafeArea()

            ZStack(alignment: .topLeading) {
                surface
                cardContent
                    .frame(width: layout.width, height: targetHeight, alignment: .top)
                    .offset(x: layout.x, y: buttonRect.minY)
            }
            .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
            .clipShape(shape)
            .contentShape(shape)
            .shadow(color: .black.opacity((theme.isDark ? 0.4 : 0.16) * progress), radius: 22, y: 8)
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
        .onAppear(perform: open)
    }

    private var surface: some View {
        Color.clear
            .morphGlass(in: shape)
            .overlay(theme.background.opacity(0.55 * Double(progress)).clipShape(shape))
            .overlay(shape.stroke(theme.cardBorder.opacity(0.35 * Double(progress)), lineWidth: 0.5))
    }

    private var cardContent: some View {
        VStack(spacing: 0) {
            headerRow
            ModelPickerContent(
                models: models,
                selectedModelId: selectedModelId,
                serverBaseURL: serverBaseURL,
                authToken: authToken,
                isAdmin: isAdmin,
                pinnedModelIds: pinnedModelIds,
                onEdit: onEdit.map { edit in { model in close(then: { edit(model) }) } },
                onTogglePin: onTogglePin,
                onSelect: { model in
                    onSelect(model)
                    close()
                },
                onSearchFocusChange: { focused in
                    withAnimation(MorphCardMetrics.spring) { searching = focused }
                },
                contentRevealed: revealed,
                showsHeader: false
            )
            .padding(.top, 4)
        }
    }

    /// The button's own label, drawn exactly over the button so the button appears
    /// to open into the card. Tap it, or swipe up on it, to close.
    private var headerRow: some View {
        ZStack(alignment: .topLeading) {
            Button { close() } label: {
                label(180 * Double(progress))
                    .frame(width: buttonRect.width, height: buttonRect.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: buttonRect.minX - layout.x)
            .accessibilityLabel("Close model picker")
        }
        .frame(maxWidth: .infinity, minHeight: buttonRect.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 12).onEnded { value in
                if value.translation.height < -24 { close() }
            }
        )
    }

    // MARK: Open / close

    private func open() {
        guard !reduceMotion else {
            progress = 1
            revealed = true
            return
        }
        withAnimation(MorphCardMetrics.spring) { progress = 1 }
        // Start dealing rows in while the spring settles, not after it stops.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if !closing { revealed = true }
        }
    }

    private func close(then action: (() -> Void)? = nil) {
        guard !closing else { return }
        closing = true
        revealed = false
        let hadKeyboard = keyboardHeight > 0
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let finish = {
            onClosed()
            action?()
        }
        guard !reduceMotion else {
            progress = 0
            finish()
            return
        }
        // With the keyboard up, let it start leaving first so the card isn't resized by
        // it and shrunk at the same moment.
        let delay = hadKeyboard ? 0.12 : 0.04
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(MorphCardMetrics.closeSpring) { progress = 0 } completion: { finish() }
        }
    }
}
