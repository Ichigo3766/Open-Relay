import SwiftUI

// MARK: - Morph Card Surface, Close Button & Animation

extension ComposerMorphCardView {
    @ViewBuilder
    func surface(_ shape: MorphShape) -> some View {
        if isCamera {
            // Glass first (matches the composer at progress 0), then black for the viewfinder.
            Color.clear
                .morphGlass(in: shape)
                .overlay(Color.black.opacity(Double(min(1, progress * 1.6))).clipShape(shape))
        } else {
            Color.clear
                .morphGlass(in: shape)
                // Background tint fades in so menu text stays readable over busy chats.
                .overlay(theme.background.opacity(0.62 * Double(progress)).clipShape(shape))
                .overlay(shape.stroke(theme.cardBorder.opacity(0.35 * Double(progress)), lineWidth: 0.5))
        }
    }

    // MARK: Photo Hand-off

    /// The captured photo, interpolated by `progress` from the full card (1) to
    /// its composer tile (0). Driven by the same spring as the card, so the photo
    /// lands on the tile exactly as the card becomes the composer again.
    func flyingPhoto(_ image: UIImage) -> some View {
        let card = CGRect(x: composerRect.minX, y: composerRect.maxY - targetHeight,
                          width: composerRect.width, height: targetHeight)
        let tile = handoffTileRect ?? CGRect(x: composerRect.minX + 10, y: composerRect.minY + 10,
                                             width: ChatInputField.attachmentTileSize,
                                             height: ChatInputField.attachmentTileSize)
        let p = progress
        let rect = CGRect(x: tile.minX + (card.minX - tile.minX) * p,
                          y: tile.minY + (card.minY - tile.minY) * p,
                          width: tile.width + (card.width - tile.width) * p,
                          height: tile.height + (card.height - tile.height) * p)
        let corner = 14 + (MorphCardMetrics.cornerRadius - 14) * p

        return Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: max(1, rect.width), height: max(1, rect.height))
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .shadow(color: .black.opacity(0.18 * (1 - p)), radius: 6, y: 2)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    var closeButton: some View {
        Button {
            Haptics.play(.light)
            request.onDismissRequest()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                // The composer's + turns into × as the card grows.
                .rotationEffect(.degrees(45 * Double(progress)))
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(theme.surfaceContainer.opacity((theme.isDark ? 0.6 : 0.9) * Double(progress)))
                )
                .contentShape(Circle())
        }
        .buttonStyle(MorphPressStyle())
        .accessibilityLabel("Close")
    }

    func open() {
        guard !reduceMotion else {
            progress = 1
            revealed = true
            request.onOpened()
            return
        }
        withAnimation(MorphCardMetrics.spring) {
            progress = 1
        } completion: {
            request.onOpened()
        }
        // Start dealing rows in while the spring settles (not after it fully stops).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            if !request.isClosing { revealed = true }
        }
    }

    func close() {
        revealed = false
        guard !reduceMotion else {
            progress = 0
            request.onClosed()
            return
        }
        withAnimation(MorphCardMetrics.closeSpring) {
            progress = 0
        } completion: {
            request.onClosed()
        }
    }
}
