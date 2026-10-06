import SwiftUI
import UIKit

// MARK: - Composer Morph Card (composer side)
//
// The composer owns the open/close state. The chat screen draws the card
// (ComposerMorphOverlayHost) from the composer's exact frame, so the composer
// itself never changes size and the message list never re-lays out.

extension ChatInputField {
    /// The card currently requested from the chat screen (nil = closed).
    var morphRequest: ComposerMorphRequest? {
        guard let morph else { return nil }
        return ComposerMorphRequest(
            kind: morph,
            menuExpanded: morphMenuExpanded,
            isClosing: morphClosing,
            content: AnyView(morphContent(morph)),
            onOpened: { morphDidOpen() },
            onClosed: { morphDidClose() },
            onDismissRequest: { closeMorph(refocus: morph == .camera) },
            handoffImage: morphHandoff?.image
        )
    }

    func openMorph(_ target: ComposerMorph, cameraFromMenu fromMenu: Bool = false) {
        guard isEnabled, morph == nil else { return }
        if target == .camera && onCameraCaptured == nil {
            onCameraCapture?()
            return
        }
        cameraFromMenu = fromMenu
        morphClosing = false
        morphOpened = false
        morphMenuExpanded = false
        morphPendingAction = nil
        morphRefocusOnClose = false
        collapseComposer()

        let keyboardUp = isKeyboardVisible || textViewFocused
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isFocused = false
        // Let the keyboard get going first so the two animations don't fight.
        if keyboardUp {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { morph = target }
        } else {
            morph = target
        }
    }

    /// Shrinks the card back into the composer. `action` runs once it has fully
    /// closed (no fixed delays); `refocus` brings the keyboard back up afterwards.
    func closeMorph(then action: (() -> Void)? = nil, refocus: Bool = false) {
        guard morph != nil else { action?(); return }
        guard !morphClosing else { return }
        morphPendingAction = action
        morphRefocusOnClose = refocus
        morphClosing = true
    }

    private func morphDidOpen() {
        guard !morphClosing else { return }
        morphOpened = true
        // Deferred until the card has settled, so loading doesn't stutter the grow.
        if morph == .menu { onToolsSheetPresented?() }
    }

    private func morphDidClose() {
        let action = morphPendingAction
        let refocus = morphRefocusOnClose
        let landedPhoto = morphHandoff != nil
        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) {
            morph = nil
            morphClosing = false
            morphOpened = false
            morphMenuExpanded = false
            morphPendingAction = nil
            morphRefocusOnClose = false
            // The flying photo is exactly over its tile now: swap it for the real one.
            morphHandoff = nil
        }
        if landedPhoto { Haptics.play(.light) }
        action?()
        if refocus {
            NotificationCenter.default.post(name: .chatInputFieldRequestFocus, object: nil)
        }
    }

    /// Hands a new attachment from the camera card to the composer as one motion:
    /// the tile is added first (hidden, while the composer is still under the
    /// card), then once it's laid out the card shrinks into the composer while
    /// `image` flies from the viewfinder into that tile.
    func landInComposer(image: UIImage?, add: () -> Void) {
        let before = Set(attachments.map(\.id))
        // No animation: the composer is hidden under the card, and its final
        // (taller) frame must be known right away for the card to aim at.
        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) { add() }
        let added = attachments.last { !before.contains($0.id) }
        if let image, let added, !reduceMotionEnabled {
            morphHandoff = ComposerMorphHandoff(attachmentId: added.id, image: image)
            // One run-loop turn so the taller composer and the tile's frame are
            // in place before the card starts aiming at them.
            DispatchQueue.main.async { closeMorph(refocus: true) }
        } else {
            closeMorph(refocus: true)
        }
    }

    private var reduceMotionEnabled: Bool { UIAccessibility.isReduceMotionEnabled }

    func showCameraFromMenu() {
        cameraFromMenu = true
        withAnimation(MorphCardMetrics.spring) {
            morphMenuExpanded = false
            morph = .camera
        }
    }

    func backToMenu() {
        withAnimation(MorphCardMetrics.spring) { morph = .menu }
    }

    @ViewBuilder
    private func morphContent(_ current: ComposerMorph) -> some View {
        switch current {
        case .menu:
            MorphMenuContent(menuExpanded: morphMenuExpanded) { revealed in
                toolsMenu(revealed: revealed)
            }
        case .camera:
            CameraCaptureCard(
                onBack: cameraFromMenu ? { backToMenu() } : nil,
                onClose: { closeMorph(refocus: true) },
                onCapture: { image in
                    Haptics.notify(.success)
                    ShortcutDonationService.donateCameraChat()
                    landInComposer(image: image) {
                        onCameraCaptured?(image)
                    }
                },
                onScan: { pages in
                    guard let attachment = FileAttachmentService.makeScanAttachment(pages: pages) else {
                        closeMorph(refocus: true)
                        return
                    }
                    // A single page lands as a photo tile; multi-page PDFs show as a
                    // file card, so they just appear as the card closes.
                    let flying = attachment.type == .image ? pages.first : nil
                    landInComposer(image: flying) {
                        if let onAttachmentsCreated {
                            onAttachmentsCreated([attachment])
                        } else {
                            attachments.append(attachment)
                        }
                    }
                }
            )
        }
    }
}

/// Reads the reveal flag from the overlay and leaves room for the × button.
private struct MorphMenuContent<Menu: View>: View {
    let menuExpanded: Bool
    @ViewBuilder let menu: (Bool) -> Menu
    @Environment(\.morphContentRevealed) private var revealed

    var body: some View {
        menu(revealed)
            // Room for the × in the card's top-left corner on the main page.
            .padding(.top, menuExpanded ? 0 : 48)
            .animation(MorphCardMetrics.spring, value: menuExpanded)
    }
}

extension Notification.Name {
    /// Widget / Siri "Camera Chat": open the in-composer camera directly.
    static let composerOpenCamera = Notification.Name("com.openui.input.openCamera")
}
