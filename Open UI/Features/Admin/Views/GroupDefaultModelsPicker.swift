import SwiftUI

/// Multi-select list of models for a group's defaults (order = selection order).
struct GroupDefaultModelsPicker: View {
    let models: [AIModel]
    @Binding var selection: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [AIModel] {
        query.isEmpty ? models : models.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { model in
                Button {
                    if let idx = selection.firstIndex(of: model.id) { selection.remove(at: idx) }
                    else { selection.append(model.id) }
                } label: {
                    HStack {
                        Text(model.name)
                        Spacer()
                        if let idx = selection.firstIndex(of: model.id) {
                            Text("\(idx + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .searchable(text: $query)
            .navigationTitle("Default Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { selection = [] }.disabled(selection.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
