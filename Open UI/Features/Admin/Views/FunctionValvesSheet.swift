import SwiftUI

/// Dynamic form for configuring a function's valves (admin or user-level).
/// Mirrors ValvesSheet (from ToolEditorView) but uses FunctionsManager endpoints.
struct FunctionValvesSheet: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let functionId: String
    /// When true, uses the user-valve endpoints (/valves/user, /valves/user/spec, /valves/user/update).
    /// When false (default), uses the admin-valve endpoints (/valves, /valves/spec, /valves/update).
    var isUserValves: Bool = false

    @State private var spec: [String: Any] = [:]
    @State private var values: [String: Any] = [:]
    @State private var editValues: [String: String] = [:]
    @State private var defaultKeys: Set<String> = []
    @State private var specKeyOrder: [String]? = nil
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var manager: FunctionsManager? { dependencies.functionsManager }

    private var propertyKeys: [String] {
        guard let props = spec["properties"] as? [String: Any] else { return [] }
        if let order = spec["order"] as? [String] {
            return order.filter { props[$0] != nil }
        }
        if let orderedKeys = specKeyOrder, !orderedKeys.isEmpty {
            let keySet = Set(props.keys)
            let ordered = orderedKeys.filter { keySet.contains($0) }
            if !ordered.isEmpty { return ordered }
        }
        return props.keys.sorted()
    }

    /// Required fields from the JSON Schema "required" array.
    private var requiredKeys: Set<String> {
        Set(spec["required"] as? [String] ?? [])
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: Spacing.lg) {
                        Spacer()
                        ProgressView().controlSize(.large).tint(theme.brandPrimary)
                        Text("Loading valves…")
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textSecondary)
                        Spacer()
                    }
                } else if propertyKeys.isEmpty {
                    VStack(spacing: Spacing.lg) {
                        Spacer()
                        Image(systemName: "slider.horizontal.3")
                            .scaledFont(size: 44)
                            .foregroundStyle(theme.textTertiary)
                        Text("No valves")
                            .scaledFont(size: 18, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                        Text("This function has no configurable settings.")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Spacing.xl)
                        Spacer()
                    }
                } else {
                    valvesForm
                }
            }
            .background(theme.background)
            .navigationTitle(isUserValves ? "User Valves" : "Valves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving {
                        ProgressView().tint(theme.brandPrimary)
                    } else {
                        Button("Save") {
                            Task { await save() }
                        }
                        .scaledFont(size: 16, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                        .disabled(propertyKeys.isEmpty)
                    }
                }
            }
            .alert("Error", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .task { await loadValves() }
        .presentationBackground(theme.background)
    }

    // MARK: - Valves Form

    private var valvesForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                let props = spec["properties"] as? [String: Any] ?? [:]

                if let desc = spec["description"] as? String, !desc.isEmpty {
                    Text(desc)
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, Spacing.md)
                }

                VStack(spacing: 0) {
                    ForEach(propertyKeys, id: \.self) { key in
                        let propSchema = props[key] as? [String: Any] ?? [:]
                        valveField(key: key, schema: propSchema)

                        if key != propertyKeys.last {
                            Divider()
                                .background(theme.inputBorder.opacity(0.3))
                                .padding(.leading, Spacing.md)
                        }
                    }
                }
                .background(theme.surfaceContainer.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                        .stroke(theme.inputBorder.opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal, Spacing.md)
            }
            .padding(.vertical, Spacing.md)
        }
    }

    @ViewBuilder
    private func valveField(key: String, schema: [String: Any]) -> some View {
        let title = schema["title"] as? String ?? key
        let description = schema["description"] as? String
        let type = schema["type"] as? String ?? "string"
        let currentText = editValues[key] ?? ""
        let isRequired = requiredKeys.contains(key)

        // Detect special input metadata
        let inputMeta = schema["input"] as? [String: Any]
        let inputType = inputMeta?["type"] as? String  // "password", "select", "multiselect"
        let inputOptions = inputMeta?["options"] as? [[String: String]]  // [{value:, label:}, ...]

        // Detect enum values for a native picker
        let enumValues = schema["enum"] as? [String]

        let isDefault = defaultKeys.contains(key)
        let isCustom = !isDefault

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                HStack(spacing: 4) {
                    Text(title)
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(isDefault ? theme.textTertiary : theme.textPrimary)
                    if isRequired {
                        Text("*")
                            .scaledFont(size: 14, weight: .bold)
                            .foregroundStyle(theme.brandPrimary)
                    }
                }
                Spacer()
                Button {
                    Haptics.play(.light)
                    if isDefault {
                        defaultKeys.remove(key)
                        if let v = values[key] { editValues[key] = "\(v)" }
                    } else {
                        defaultKeys.insert(key)
                    }
                } label: {
                    HStack(spacing: 3) {
                        if isCustom {
                            Image(systemName: "xmark")
                                .scaledFont(size: 9, weight: .bold)
                                .foregroundStyle(theme.brandPrimary)
                        }
                        Text(isDefault ? "Default" : "Custom")
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(isCustom ? theme.brandPrimary : theme.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        isCustom
                            ? theme.brandPrimary.opacity(0.12)
                            : theme.surfaceContainerHighest.opacity(0.6)
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, 12)

            if let desc = description, !desc.isEmpty {
                Text(desc)
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, 3)
            }

            // Input — only shown when Custom (hidden entirely when Default)
            if !isDefault {
                if type == "boolean" {
                    // Boolean → Toggle
                    HStack {
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { currentText == "true" || currentText == "1" },
                            set: { editValues[key] = $0 ? "true" : "false" }
                        ))
                        .tint(theme.brandPrimary)
                        .labelsHidden()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 10)
                } else if let options = enumValues ?? inputOptions?.map({ $0["value"] ?? $0["label"] ?? "" }),
                          !options.isEmpty,
                          inputType != "multiselect" {
                    // Enum or select → Menu picker
                    let labels: [String] = inputOptions?.map { $0["label"] ?? $0["value"] ?? "" } ?? options
                    Menu {
                        ForEach(Array(zip(options, labels)), id: \.0) { value, label in
                            Button(label) {
                                editValues[key] = value
                            }
                        }
                    } label: {
                        HStack {
                            let displayLabel: String = {
                                if let idx = options.firstIndex(of: currentText), idx < labels.count {
                                    return labels[idx]
                                }
                                return currentText.isEmpty ? (options.first ?? "") : currentText
                            }()
                            Text(displayLabel)
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.textTertiary)
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 10)
                        .background(theme.surfaceContainer.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(theme.inputBorder.opacity(0.2), lineWidth: 1)
                        )
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                } else if inputType == "password" {
                    // Password → SecureField
                    SecureField("", text: Binding(
                        get: { editValues[key] ?? "" },
                        set: { editValues[key] = $0 }
                    ))
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                    .padding(10)
                    .background(theme.surfaceContainer.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.inputBorder.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 8)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                } else if type == "array" {
                    // Array → comma-separated TextEditor
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: Binding(
                            get: { editValues[key] ?? "" },
                            set: { editValues[key] = $0 }
                        ))
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 50, maxHeight: 100)
                        .padding(8)
                        .background(theme.surfaceContainer.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(theme.inputBorder.opacity(0.2), lineWidth: 1)
                        )
                        .autocorrectionDisabled()
                        Text("Comma-separated values")
                            .scaledFont(size: 11)
                            .foregroundStyle(theme.textTertiary)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 8)
                } else {
                    // Default → TextEditor (multiline)
                    TextEditor(text: Binding(
                        get: { editValues[key] ?? "" },
                        set: { editValues[key] = $0 }
                    ))
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 50, maxHeight: 120)
                    .padding(8)
                    .background(theme.surfaceContainer.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.inputBorder.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 8)
                    .keyboardType(type == "integer" || type == "number" ? .decimalPad : .default)
                    .autocorrectionDisabled()
                }
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Load

    private func loadValves() async {
        guard !functionId.isEmpty, let manager else { isLoading = false; return }
        isLoading = true
        do {
            // Fetch spec — branch on isUserValves
            let (fetchedSpec, keyOrder): ([String: Any], [String])
            if isUserValves {
                (fetchedSpec, keyOrder) = try await manager.getUserValvesSpecWithOrder(id: functionId)
            } else {
                (fetchedSpec, keyOrder) = try await manager.getValvesSpecWithOrder(id: functionId)
            }
            spec = fetchedSpec
            specKeyOrder = keyOrder.isEmpty ? nil : keyOrder

            // Fetch current values
            let fetchedValues: [String: Any]
            if isUserValves {
                fetchedValues = (try? await manager.getUserValves(id: functionId)) ?? [:]
            } else {
                fetchedValues = (try? await manager.getValves(id: functionId)) ?? [:]
            }
            values = fetchedValues

            // Seed edit fields from spec defaults + any server-stored overrides.
            let props = fetchedSpec["properties"] as? [String: Any] ?? [:]
            for key in props.keys {
                let propSchema = props[key] as? [String: Any] ?? [:]
                if let v = fetchedValues[key] {
                    // Server has an override — decode arrays as comma-joined string
                    if let arr = v as? [Any] {
                        editValues[key] = arr.map { "\($0)" }.joined(separator: ", ")
                    } else {
                        editValues[key] = "\(v)"
                    }
                } else {
                    // No server override → seed spec default, mark as Default
                    defaultKeys.insert(key)
                    if let defVal = propSchema["default"] {
                        if let arr = defVal as? [Any] {
                            editValues[key] = arr.map { "\($0)" }.joined(separator: ", ")
                        } else {
                            editValues[key] = "\(defVal)"
                        }
                    } else {
                        editValues[key] = ""
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Save

    private func save() async {
        guard let manager else { return }
        isSaving = true

        var payload: [String: Any] = [:]
        let props = spec["properties"] as? [String: Any] ?? [:]
        for key in propertyKeys {
            if defaultKeys.contains(key) {
                if values[key] != nil {
                    payload[key] = NSNull()
                }
                continue
            }
            let propSchema = props[key] as? [String: Any] ?? [:]
            let type = propSchema["type"] as? String ?? "string"
            let raw = editValues[key] ?? ""
            switch type {
            case "integer":
                payload[key] = Int(raw) ?? 0
            case "number":
                payload[key] = Double(raw) ?? 0.0
            case "boolean":
                payload[key] = raw == "true" || raw == "1"
            case "array":
                // Split comma-separated string back into an array
                let items = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                payload[key] = items
            default:
                payload[key] = raw
            }
        }

        guard !payload.isEmpty else {
            dismiss()
            isSaving = false
            return
        }

        do {
            if isUserValves {
                _ = try await manager.updateUserValves(id: functionId, values: payload)
            } else {
                _ = try await manager.updateValves(id: functionId, values: payload)
            }
            Haptics.notify(.success)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.notify(.error)
        }
        isSaving = false
    }
}
