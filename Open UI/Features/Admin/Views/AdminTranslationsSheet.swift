import SwiftUI

/// Editor for Admin → General → Translations. Edits a copy; "Done" writes the result back
/// into the admin config (`I18N`), which is sent with the Features Save button.
struct AdminTranslationsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Bindable var viewModel: AdminGeneralSettingsViewModel

    @State private var rows: [I18nRow] = []
    @State private var error: String?
    @State private var pickerRow: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Replace any interface text for a language. The original text must match the English string exactly, and {{placeholders}} must stay the same.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach($rows) { $row in
                    Section {
                        TextField("Original text", text: $row.original, axis: .vertical)
                            .font(.subheadline.weight(.semibold))
                        ForEach(row.translations.keys.sorted(), id: \.self) { locale in
                            HStack(alignment: .top) {
                                Text(locale).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                                TextField("Translation", text: Binding(
                                    get: { row.translations[locale] ?? "" },
                                    set: { row.translations[locale] = $0 }
                                ), axis: .vertical)
                                Button { row.translations.removeValue(forKey: locale) } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Button { pickerRow = row.id } label: { Label("Add language", systemImage: "globe") }
                    }
                }
                .onDelete { rows.remove(atOffsets: $0) }

                Button { rows.append(I18nRow(original: "", translations: [:])) } label: {
                    Label("Add Translation", systemImage: "plus")
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("Translations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { commit() } }
            }
            .sheet(item: Binding(get: { pickerRow.map { PickBox(id: $0) } }, set: { pickerRow = $0?.id })) { box in
                LocalePickerSheet(selected: "") { code in
                    if let i = rows.firstIndex(where: { $0.id == box.id }), rows[i].translations[code] == nil {
                        rows[i].translations[code] = ""
                    }
                    pickerRow = nil
                }
            }
            .onAppear {
                rows = I18nOverrides.rows(from: viewModel.authConfig.raw["I18N"] as? [String: Any] ?? [:])
            }
        }
    }

    private struct PickBox: Identifiable { let id: UUID }

    private func commit() {
        do {
            viewModel.authConfig.raw["I18N"] = try I18nOverrides.payload(from: rows)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
