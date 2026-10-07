import SwiftUI

// MARK: - Model Selector Sheet

/// Bottom-sheet model picker, used where there is no nav-bar button to grow a card
/// from (e.g. Automations). The chat uses `ModelPickerCard` instead; both render the
/// same `ModelPickerContent`, so the features never drift apart.
struct ModelSelectorSheet: View {
    let models: [AIModel]
    let selectedModelId: String?
    let serverBaseURL: String
    let authToken: String?
    let isAdmin: Bool
    let pinnedModelIds: [String]
    let onEdit: ((AIModel) -> Void)?
    let onTogglePin: ((String) -> Void)?
    let onSelect: (AIModel) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Grows to full height when search is focused so the keyboard never hides results.
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ModelPickerContent(
                models: models,
                selectedModelId: selectedModelId,
                serverBaseURL: serverBaseURL,
                authToken: authToken,
                isAdmin: isAdmin,
                pinnedModelIds: pinnedModelIds,
                onEdit: onEdit.map { edit in { model in dismiss(); edit(model) } },
                onTogglePin: onTogglePin,
                onSelect: { model in
                    onSelect(model)
                    dismiss()
                },
                onSearchFocusChange: { focused in
                    if focused && detent != .large {
                        withAnimation(MicroAnimation.gentle) { detent = .large }
                    }
                }
            )
            SheetCloseButton { dismiss() }
                .padding(.trailing, 16)
                .padding(.top, 8)
        }
        .modifier(ModelSheetSurface())
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(24)
        // Disable background interaction so UIKit can use a cheaper, non-live
        // compositor pass instead of snapshotting the presenting view tree.
        .presentationBackgroundInteraction(.disabled)
        .onDisappear {
            // Free avatar image memory after the picker closes (disk cache is kept).
            Task { await ImageCacheService.shared.clearMemory() }
        }
    }
}

/// Liquid Glass sheet surface on iOS 26+, the solid theme background before that.
private struct ModelSheetSurface: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // The system draws its own glass sheet background; keep ours clear.
            content.presentationBackground(.clear)
        } else {
            content
                .background(theme.background)
                .presentationBackground(theme.background)
        }
    }
}
