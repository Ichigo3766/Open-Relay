import SwiftUI

struct NamedModelControlsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: AIModel
    let apiClient: APIClient
    let onSaved: () async -> Void
    @State private var selections: [String: String] = [:]
    @State private var loading = true
    @State private var saving = false
    @State private var loaded = false
    @State private var error: String?

    private var controls: [NamedModelControl] { model.namedControls ?? [] }

    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView() }
                if let error {
                    Text(error).foregroundStyle(.red)
                    if !loaded { Button("Retry") { Task { await load() } } }
                }
                if loaded {
                    Section(model.name) {
                        ForEach(controls) { control in
                            VStack(alignment: .leading, spacing: 8) {
                                if control.display == "slider", control.options.count >= 2 {
                                    slider(control)
                                } else {
                                    Picker(control.label, selection: selection(control)) {
                                        Text(control.defaultLabel).tag("")
                                        ForEach(control.options) { Text($0.label).tag($0.id) }
                                    }
                                    .pickerStyle(.menu)
                                }
                                if let description = control.description, !description.isEmpty {
                                    Text(description).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Text("Choices are remembered for this model on your account.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Model Controls")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(saving)
            .interactiveDismissDisabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!loaded || saving)
                }
            }
            .task { await load() }
        }
    }

    private func selection(_ control: NamedModelControl) -> Binding<String> {
        Binding(get: { selections[control.id] ?? "" }, set: { selections[control.id] = $0.isEmpty ? nil : $0 })
    }

    private func slider(_ control: NamedModelControl) -> some View {
        let current = selections[control.id] ?? control.defaultOption
        let index = control.options.firstIndex { $0.id == current } ?? 0
        let label = control.options.first { $0.id == current }?.label ?? "Default"
        return VStack(alignment: .leading, spacing: 8) {
            LabeledContent(control.label, value: label)
            Slider(value: Binding(
                get: { Double(index) },
                set: { selections[control.id] = control.options[Int($0.rounded())].id }
            ), in: 0...Double(control.options.count - 1), step: 1)
                .accessibilityLabel(control.label)
                .accessibilityValue(label)
            HStack {
                Text(control.options.first?.label ?? "")
                Spacer()
                Text(control.options.last?.label ?? "")
            }.font(.caption).foregroundStyle(.secondary)
            Button(control.defaultLabel) { selections.removeValue(forKey: control.id) }
                .font(.footnote).disabled(selections[control.id] == nil)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let settings = try await apiClient.getUserSettings()
            let saved = UserDefaultParams(from: settings["ui"] as? [String: Any] ?? [:]).modelControls?[model.id] ?? [:]
            selections = saved.filter { id, value in controls.first { $0.id == id }?.options.contains { $0.id == value } == true }
            loaded = true
            error = nil
        } catch {
            self.error = error.localizedDescription
            loading = false
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await apiClient.saveModelControlSelections(modelID: model.id, controlIDs: controls.map(\.id), selections: selections)
            await onSaved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
