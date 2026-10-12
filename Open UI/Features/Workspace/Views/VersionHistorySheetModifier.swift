import SwiftUI

/// Adds a version-history sheet to a workspace editor. When a version is
/// made live, the editor closes on dismiss so reopening shows the restored data.
struct VersionHistorySheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let resource: VersionedResource?
    let liveVersionId: String?
    let onRestoredDismiss: () -> Void

    @State private var restored = false

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            if restored { restored = false; onRestoredDismiss() }
        }) {
            if let resource {
                ResourceVersionHistorySheet(
                    resource: resource,
                    title: String(localized: "Version History"),
                    liveVersionId: liveVersionId,
                    onRestored: { restored = true }
                )
            }
        }
    }
}

extension View {
    func versionHistorySheet(
        isPresented: Binding<Bool>,
        resource: VersionedResource?,
        liveVersionId: String?,
        onRestoredDismiss: @escaping () -> Void
    ) -> some View {
        modifier(VersionHistorySheetModifier(
            isPresented: isPresented, resource: resource,
            liveVersionId: liveVersionId, onRestoredDismiss: onRestoredDismiss
        ))
    }
}

/// Toolbar clock button that opens the version history.
struct VersionHistoryToolbarButton: View {
    let action: () -> Void
    var body: some View {
        Button("Version History", systemImage: "clock.arrow.circlepath", action: action)
            .labelStyle(.iconOnly)
    }
}
