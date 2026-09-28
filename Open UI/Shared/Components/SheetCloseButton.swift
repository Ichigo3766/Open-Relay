import SwiftUI

/// System-styled dismissal for sheets whose custom headers are outside a toolbar.
struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var button: some View {
        Button("Close", systemImage: "xmark", action: action)
            .labelStyle(.iconOnly)
            .tint(.secondary)
            .buttonBorderShape(.circle)
            .controlSize(.large)
    }
}
