import SwiftUI

// MARK: - Tool Valves Kind

/// Determines which API endpoints to use when loading/saving user-level valves.
enum UserValvesKind: Identifiable {
    case tool(String)
    case function(String)

    var id: String {
        switch self {
        case .tool(let id): return id
        case .function(let id): return id
        }
    }
}

// MARK: - User Valves Sheet

/// Dynamic form for editing a tool or function's user-level valves.
/// Uses user-scoped endpoints (/valves/user, /valves/user/spec, /valves/user/update).
/// Supports boolean toggles, enum pickers, and text/number fields.
/// Mirrors FunctionValvesSheet style with Default/Custom pill toggles.
struct UserValvesSheet: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let kind: UserValvesKind

    @State private var spec: [String: Any] = [:]
    @State private var values: [String: Any] = [:]
    @State private var editValues: [String: String] = [:]
    @State private var defaultKeys: Set<String> = []
    @State private var specKeyOrder: [String]? = nil
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var toolsManager: ToolsManager? { dependencies.toolsManager }
    private var functionsManager: FunctionsManager? { dependencies.functionsManager }

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
                        Text("This tool has no user-configurable settings.")
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
            .navigationTitle("Valves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .tint(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving {
                        ProgressView().tint(theme.brandPrimary)
                    } else {
                        Button("Save", systemImage: "checkmark") {
                            Task { await save() }
                        }
                        .labelStyle(.iconOnly)
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
        let enumOptions = schema["enum"] as? [String]
        let currentText = editValues[key] ?? ""
        let isDefault = defaultKeys.contains(key)
        let isCustom = !isDefault

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text(title)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(isDefault ? theme.textTertiary : theme.textPrimary)
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

            if !isDefault {
                if type == "boolean" {
                    // Boolean: native iOS Toggle
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
                } else if let options = enumOptions, !options.isEmpty {
                    // Enum: compact inline picker using Menu
                    HStack {
                        Spacer()
                        Menu {
                            ForEach(options, id: \.self) { option in
                                Button {
                                    editValues[key] = option
                                } label: {
                                    HStack {
                                        Text(option)
                                        if currentText == option {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(currentText.isEmpty ? (options.first ?? "") : currentText)
                                    .scaledFont(size: 13, weight: .medium)
                                    .foregroundStyle(theme.brandPrimary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .scaledFont(size: 10, weight: .semibold)
                                    .foregroundStyle(theme.brandPrimary.opacity(0.7))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(theme.brandPrimary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .menuOrder(.fixed)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 8)
                } else {
                    // Text / Number: editable TextEditor
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
                    .keyboardType(type == "integer" || type == "number" ? .numbersAndPunctuation : .default)
                    .autocorrectionDisabled()
                }
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Load

    private func loadValves() async {
        isLoading = true
        do {
            let (fetchedSpec, keyOrder): ([String: Any], [String])
            let fetchedValues: [String: Any]

            switch kind {
            case .tool(let id):
                guard let manager = toolsManager else { isLoading = false; return }
                (fetchedSpec, keyOrder) = try await manager.getUserValvesSpecWithOrder(id: id)
                fetchedValues = (try? await manager.getUserValves(id: id)) ?? [:]
            case .function(let id):
                guard let manager = functionsManager else { isLoading = false; return }
                (fetchedSpec, keyOrder) = try await manager.getUserValvesSpecWithOrder(id: id)
                fetchedValues = (try? await manager.getUserValves(id: id)) ?? [:]
            }

            spec = fetchedSpec
            values = fetchedValues
            specKeyOrder = keyOrder.isEmpty ? nil : keyOrder

            let props = fetchedSpec["properties"] as? [String: Any] ?? [:]
            for key in props.keys {
                let propSchema = props[key] as? [String: Any] ?? [:]
                if let v = fetchedValues[key] {
                    editValues[key] = "\(v)"
                } else {
                    defaultKeys.insert(key)
                    if let defVal = propSchema["default"] {
                        editValues[key] = "\(defVal)"
                    } else {
                        editValues[key] = ""
                    }
                }
            }
        } catch is CancellationError {
            // Task was cancelled (e.g. SwiftUI re-render during sheet presentation) — not a real error
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession-level cancel — not a real error
        } catch let apiError as APIError {
            if case .cancelled = apiError {
                // NetworkManager-wrapped cancel — not a real error
            } else {
                errorMessage = apiError.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Save

    private func save() async {
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
            switch kind {
            case .tool(let id):
                guard let manager = toolsManager else { isSaving = false; return }
                _ = try await manager.updateUserValves(id: id, values: payload)
            case .function(let id):
                guard let manager = functionsManager else { isSaving = false; return }
                _ = try await manager.updateUserValves(id: id, values: payload)
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
