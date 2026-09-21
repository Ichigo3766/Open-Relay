import SwiftUI

struct MessageActionsSettingsView: View {
    @Environment(\.theme) private var theme
    @AppStorage(MessageActionPreferences.orderKey) private var storedOrder = ""
    @AppStorage(MessageActionPreferences.hiddenKey) private var storedHidden = ""
    @AppStorage(MessageActionPreferences.shortcutsKey) private var storedShortcuts = ""
    @State private var editorAction: ShortcutMessageAction?

    let availableBuiltInActions: Set<MessageAction>

    private var shortcuts: [ShortcutMessageAction] {
        ShortcutMessageAction.decodeStored(storedShortcuts)
    }

    private var preferences: MessageActionPreferences {
        MessageActionPreferences(order: storedOrder, hidden: storedHidden, shortcuts: shortcuts)
    }

    private var displayedItems: [MessageActionItem] {
        preferences.order.filter(isAvailable)
    }

    var body: some View {
        List {
            Section {
                ForEach(displayedItems) { item in
                    actionRow(item)
                }
                .onMove(perform: moveItems)
            } header: {
                Text("Assistant Message Actions")
            } footer: {
                Text("Server actions unavailable to your account are omitted. Order, visibility, and Shortcut actions stay on this device. Some buttons only appear when applicable to a message.")
            }

            Section {
                Button {
                    editorAction = ShortcutMessageAction()
                } label: {
                    Label("Add Shortcut Action", systemImage: "plus.circle.fill")
                }
                .tint(theme.brandPrimary)
                .accessibilityIdentifier("messageAction.addShortcut")
            } footer: {
                Text("Shortcut actions receive the assistant message as text input.")
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
        .sheet(item: $editorAction) { action in
            ShortcutMessageActionEditor(
                action: action,
                isNew: !shortcuts.contains(where: { $0.id == action.id }),
                onSave: saveShortcut,
                onDelete: deleteShortcut
            )
        }
    }

    @ViewBuilder
    private func actionRow(_ item: MessageActionItem) -> some View {
        switch item {
        case .builtIn(let action):
            Toggle(isOn: visibilityBinding(for: item)) {
                Label(action.title, systemImage: action.iconName)
            }
            .tint(theme.brandPrimary)
            .accessibilityIdentifier("messageAction.\(action.rawValue)")

        case .shortcut(let action):
            HStack(spacing: 12) {
                Button {
                    editorAction = action
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: action.symbolName)
                            .frame(width: 22)
                            .foregroundStyle(theme.brandPrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.name)
                                .foregroundStyle(theme.textPrimary)
                            Text(action.shortcutName)
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                Toggle(action.name, isOn: visibilityBinding(for: item))
                    .labelsHidden()
                    .tint(theme.brandPrimary)
            }
            .accessibilityIdentifier("messageAction.\(action.storageID)")
        }
    }

    private func visibilityBinding(for item: MessageActionItem) -> Binding<Bool> {
        Binding(
            get: { preferences.isVisible(item) },
            set: { visible in
                var updated = preferences
                updated.setVisible(visible, for: item)
                storedHidden = updated.storedHidden
            }
        )
    }

    private func isAvailable(_ item: MessageActionItem) -> Bool {
        switch item {
        case .builtIn(let action): availableBuiltInActions.contains(action)
        case .shortcut: true
        }
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        var reordered = displayedItems
        reordered.move(fromOffsets: source, toOffset: destination)

        var updated = preferences
        updated.reorder(reordered)
        storedOrder = updated.storedOrder
    }

    private func saveShortcut(_ action: ShortcutMessageAction) {
        var updatedShortcuts = shortcuts
        if let index = updatedShortcuts.firstIndex(where: { $0.id == action.id }) {
            updatedShortcuts[index] = action
        } else {
            updatedShortcuts.append(action)
        }
        persistShortcuts(updatedShortcuts)
    }

    private func deleteShortcut(_ action: ShortcutMessageAction) {
        persistShortcuts(shortcuts.filter { $0.id != action.id })
    }

    private func persistShortcuts(_ updatedShortcuts: [ShortcutMessageAction]) {
        storedShortcuts = ShortcutMessageAction.encodeStored(updatedShortcuts)

        let updatedPreferences = MessageActionPreferences(
            order: storedOrder,
            hidden: storedHidden,
            shortcuts: updatedShortcuts
        )
        storedOrder = updatedPreferences.storedOrder
        storedHidden = updatedPreferences.storedHidden
    }
}

private struct ShortcutMessageActionEditor: View {
    private static let symbols = [
        "bolt.fill", "wand.and.stars", "doc.text", "text.quote",
        "square.and.arrow.up", "tray.and.arrow.down", "note.text", "bookmark.fill",
        "tag.fill", "link", "paperplane.fill", "bubble.left.fill",
        "speaker.wave.2.fill", "headphones", "star.fill", "heart.fill"
    ]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var name: String
    @State private var shortcutName: String
    @State private var symbolName: String

    let action: ShortcutMessageAction
    let isNew: Bool
    let onSave: (ShortcutMessageAction) -> Void
    let onDelete: (ShortcutMessageAction) -> Void

    init(action: ShortcutMessageAction, isNew: Bool, onSave: @escaping (ShortcutMessageAction) -> Void,
         onDelete: @escaping (ShortcutMessageAction) -> Void) {
        self.action = action
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: action.name)
        _shortcutName = State(initialValue: action.shortcutName)
        _symbolName = State(initialValue: action.symbolName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedShortcutName: String {
        shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !trimmedShortcutName.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Button Name", text: $name, prompt: Text("Process Text"))
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("shortcutAction.name")
                    TextField("Shortcut Name", text: $shortcutName, prompt: Text("Process Assistant Text"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("shortcutAction.shortcutName")
                } header: {
                    Text("Action")
                } footer: {
                    Text("The Shortcut name must exactly match one in the Shortcuts app.")
                }

                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 12)], spacing: 12) {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            Button {
                                symbolName = symbol
                                Haptics.play(.light)
                            } label: {
                                Image(systemName: symbol)
                                    .scaledFont(size: 20, weight: .medium)
                                    .foregroundStyle(symbolName == symbol ? Color.white : theme.textPrimary)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(symbolName == symbol ? theme.brandPrimary : theme.surfaceContainer)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(symbol)
                            .accessibilityAddTraits(symbolName == symbol ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("SF Symbol")
                } footer: {
                    Text("Choose an Apple SF Symbol for the message action button.")
                }

                if !isNew {
                    Section {
                        Button("Delete Action", role: .destructive) {
                            onDelete(action)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add Shortcut Action" : "Edit Shortcut Action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(ShortcutMessageAction(
                            id: action.id,
                            name: trimmedName,
                            shortcutName: trimmedShortcutName,
                            symbolName: symbolName
                        ))
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.large])
    }
}
