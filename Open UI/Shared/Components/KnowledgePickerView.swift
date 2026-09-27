import SwiftUI

/// The # picker uses the same server results as the attachment sheets.
struct KnowledgePickerView: View {
    let query: String
    let apiClient: APIClient?
    let keyboardHeight: CGFloat
    let onSelect: (KnowledgeItem) -> Void
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    private var availableHeight: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let screen = scene?.screen.bounds.height ?? UIScreen.main.bounds.height
        let safeArea = scene?.windows.first?.safeAreaInsets
        return max(120, screen - (safeArea?.top ?? 59) - (safeArea?.bottom ?? 34) - keyboardHeight - 116)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Attach Knowledge").font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark", action: onDismiss).labelStyle(.iconOnly)
            }.padding()
            AttachmentPickerResults(apiClient: apiClient, query: query,
                                    sources: [.folders, .collections, .documents(collectionID: nil)],
                                    onSelect: onSelect)
        }
        .frame(height: min(360, availableHeight))
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }
}
