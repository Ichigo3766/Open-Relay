import SwiftUI

struct MessageActionsSettingsView: View {
    @Environment(\.theme) private var theme
    @AppStorage(MessageActionPreferences.orderKey) private var storedOrder = ""
    @AppStorage(MessageActionPreferences.hiddenKey) private var storedHidden = ""

    private var preferences: MessageActionPreferences {
        MessageActionPreferences(order: storedOrder, hidden: storedHidden)
    }

    var body: some View {
        List {
            Section {
                ForEach(preferences.order) { action in
                    Toggle(action.title, isOn: Binding(
                        get: { !preferences.hidden.contains(action) },
                        set: { visible in
                            var updated = preferences
                            if visible { updated.hidden.remove(action) }
                            else { updated.hidden.insert(action) }
                            storedHidden = updated.storedHidden
                        }
                    ))
                    .tint(theme.brandPrimary)
                    .accessibilityIdentifier("messageAction.\(action.rawValue)")
                }
                .onMove { source, destination in
                    var updated = preferences
                    updated.order.move(fromOffsets: source, toOffset: destination)
                    storedOrder = updated.storedOrder
                }
            } header: {
                Text("Assistant Message Actions")
            } footer: {
                Text("Choose which buttons appear below responses. Drag the handles to reorder them. These preferences apply on this device; server permissions still apply. Version navigation and model-provided actions remain available, and Stop stays visible during speech playback.")
            }

            Section {
                Button("Reset to Defaults") {
                    storedOrder = ""
                    storedHidden = ""
                }
                .tint(theme.brandPrimary)
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Message Actions")
        .navigationBarTitleDisplayMode(.inline)
    }
}
