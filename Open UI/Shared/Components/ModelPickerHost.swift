import SwiftUI

// MARK: - Chat Morph Overlays
//
// Draws the + menu card, the model picker card and the editor drop over the chat.
//
// These live in their own ViewModifier on purpose: `ChatDetailView`'s view builders are
// already so large that every extra modifier written directly in them grows the
// main-thread stack needed to read their type at runtime, and one too many overflows it
// (a launch crash). Folding related modifiers into one keeps those bodies small — the
// same reason `chatChromeBar` exists.

struct ChatMorphOverlaysModifier: ViewModifier {
    let isPickerOpen: Bool
    let drop: ModelEditorDropState?
    let card: (CGRect, CGSize) -> AnyView

    func body(content: Content) -> some View {
        content
            // + menu / camera card: drawn over the whole chat from the composer's frame.
            .overlayPreferenceValue(ComposerMorphKey.self) { state in
                ComposerMorphOverlayHost(state: state)
            }
            // Model picker card + editor drop: anchored to the nav-bar model button.
            .overlayPreferenceValue(ModelButtonAnchorKey.self) { anchor in
                ModelPickerHostLayer(anchor: anchor, isPickerOpen: isPickerOpen,
                                     drop: drop, card: card)
            }
    }
}

/// State of the editor drop: how far along its motion it is, and whether the editor
/// sheet has taken over (the landed bar then fades out).
struct ModelEditorDropState: Equatable {
    var progress: CGFloat
    var isHandedOff: Bool = false
}

private struct ModelPickerHostLayer: View {
    let anchor: Anchor<CGRect>?
    let isPickerOpen: Bool
    let drop: ModelEditorDropState?
    let card: (CGRect, CGSize) -> AnyView

    var body: some View {
        GeometryReader { proxy in
            if let anchor {
                let rect = proxy[anchor]
                if isPickerOpen {
                    card(rect, proxy.size)
                }
                if let drop {
                    ModelEditorDropView(progress: drop.progress, isHandedOff: drop.isHandedOff,
                                        buttonRect: rect, containerSize: proxy.size)
                }
            }
        }
        // Keep this layer full-height when the keyboard opens. The card subtracts the
        // keyboard itself; if the layer also shrank, it would be subtracted twice and
        // the card would collapse to almost nothing.
        .ignoresSafeArea(.keyboard)
    }
}

extension View {
    /// Hosts the + menu card, the model picker card and the editor drop over this view.
    func chatMorphOverlays(
        isPickerOpen: Bool,
        drop: ModelEditorDropState?,
        card: @escaping (CGRect, CGSize) -> AnyView
    ) -> some View {
        modifier(ChatMorphOverlaysModifier(isPickerOpen: isPickerOpen, drop: drop, card: card))
    }
}

// MARK: - Model Editor Sheet

/// The model editor sheet, as its own modifier (see the note above).
struct ModelEditorSheetModifier: ViewModifier {
    @Binding var detail: ModelDetail?
    let onSaved: () -> Void
    @Environment(AppDependencyContainer.self) private var dependencies

    func body(content: Content) -> some View {
        content.sheet(item: $detail) { editing in
            NavigationStack {
                ModelEditorView(existingModel: editing) { _ in
                    onSaved()
                    detail = nil
                }
            }
            .environment(dependencies)
            .themed()
        }
    }
}

extension View {
    func modelEditorSheet(detail: Binding<ModelDetail?>, onSaved: @escaping () -> Void) -> some View {
        modifier(ModelEditorSheetModifier(detail: detail, onSaved: onSaved))
    }
}

