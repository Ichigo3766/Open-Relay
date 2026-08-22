import SwiftUI

/// An inline valve-configuration form embedded directly in the Controls panel.
///
/// Mirrors OWUI's `Valves.svelte` inline approach:
/// - Loads the JSON Schema spec + current values for the selected tool/function
/// - Renders each property as a field (boolean toggle, enum picker, array comma-string, or text)
/// - Auto-saves with a 500 ms debounce on every change (no explicit Save button)
///
/// Used by `ChatContextPanel.valvesSection` when the user picks a tool or function.
struct InlineValvesForm: View {
    @Environment(AppDependencyContainer.self) private var dependencies

    let kind: UserValvesKind

    @State private var spec: [String: Any] = [:]
    @State private var values: [String: Any] = [:]
    @State private var editValues: [String: String] = [:]
    @State private var defaultKeys: Set<String> = []
    @State private var specKeyOrder: [String]? = nil
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorText: String?

    // Explicit task management — avoids cancellation races inside List
    @State private var loadTask: Task<Void, Never>?
    @State private var didLoad = false

    /// Debounce task — cancelled and replaced on every field change.
    @State private var debounceTask: Task<Void, Never>?

    private var toolsManager: ToolsManager? { dependencies.toolsManager }
    private var functionsManager: FunctionsManager? { dependencies.functionsManager }

    // MARK: - Key ordering

    private var propertyKeys: [String] {
        guard let props = spec["properties"] as? [String: Any] else { return [] }
        if let order = spec["order"] as? [String] {
            return order.filter { props[$0] != nil }
        }
        if let ordered = specKeyOrder, !ordered.isEmpty {
            let keySet = Set(props.keys)
            let filtered = ordered.filter { keySet.contains($0) }
            if !filtered.isEmpty { return filtered }
        }
        return props.keys.sorted()
    }

    // MARK: - Body

    var body: some View {
        Group {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 8)
            } else if let err = errorText {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.vertical, 4)
            } else if propertyKeys.isEmpty {
                Text("No configurable settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                valvesContent
            }
        }
        .onAppear { startLoad() }
        .onDisappear { cancelLoad() }
    }

    // MARK: - Load lifecycle (explicit task — avoids SwiftUI .task cancellation races in List)

    private func startLoad() {
        guard !didLoad else { return }
        didLoad = true
        loadTask?.cancel()
        loadTask = Task { await loadValves() }
    }

    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - Fields

    @ViewBuilder
    private var valvesContent: some View {
        let props = spec["properties"] as? [String: Any] ?? [:]
        ForEach(propertyKeys, id: \.self) { key in
            let schema = props[key] as? [String: Any] ?? [:]
            valveField(key: key, schema: schema)
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

        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(isDefault ? .secondary : .primary)
                    if let desc = description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                // Default / Custom toggle pill
                Button {
                    Haptics.play(.light)
                    if isDefault {
                        defaultKeys.remove(key)
                        // Populate edit value from saved value or schema default
                        if let v = values[key] {
                            editValues[key] = arrayToDisplayString(v, type: type, schema: schema)
                        }
                    } else {
                        defaultKeys.insert(key)
                    }
                    scheduleDebounce()
                } label: {
                    Text(isDefault ? "Default" : "Custom")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isDefault ? Color.secondary : Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            isDefault
                                ? Color(.systemFill)
                                : Color.accentColor.opacity(0.12)
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if !isDefault {
                if type == "boolean" {
                    Toggle("", isOn: Binding(
                        get: { currentText == "true" || currentText == "1" },
                        set: { newVal in
                            editValues[key] = newVal ? "true" : "false"
                            scheduleDebounce()
                        }
                    ))
                    .tint(Color.accentColor)
                    .labelsHidden()
                } else if let options = enumOptions, !options.isEmpty {
                    Menu {
                        ForEach(options, id: \.self) { option in
                            Button {
                                editValues[key] = option
                                scheduleDebounce()
                            } label: {
                                HStack {
                                    Text(option)
                                    if currentText == option { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(currentText.isEmpty ? (options.first ?? "") : currentText)
                                .font(.subheadline)
                                .foregroundStyle(Color.accentColor)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor.opacity(0.7))
                        }
                    }
                    .menuOrder(.fixed)
                } else {
                    // Handles string, number, integer, and array (displayed as comma-separated)
                    TextField(
                        type == "integer" || type == "number" ? "0"
                            : type == "array" ? "comma-separated values"
                            : "value",
                        text: Binding(
                            get: { editValues[key] ?? "" },
                            set: { editValues[key] = $0; scheduleDebounce() }
                        )
                    )
                    .font(.subheadline)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(type == "integer" || type == "number" ? .numbersAndPunctuation : .default)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    if type == "array" {
                        Text("Separate multiple values with commas")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Array helpers (mirrors OWUI: array ↔ comma-string)

    /// Converts a raw value (which may be an array or string) to a display string.
    private func arrayToDisplayString(_ value: Any, type: String, schema: [String: Any]) -> String {
        if type == "array" {
            if let arr = value as? [Any] {
                return arr.map { "\($0)" }.joined(separator: ", ")
            }
            return "\(value)"
        }
        return "\(value)"
    }

    // MARK: - Load

    private func loadValves() async {
        isLoading = true
        errorText = nil
        do {
            let (fetchedSpec, keyOrder): ([String: Any], [String])
            let fetchedValues: [String: Any]

            switch kind {
            case .tool(let id):
                guard let mgr = toolsManager else { isLoading = false; return }
                async let specTask = mgr.getUserValvesSpecWithOrder(id: id)
                async let valuesTask: [String: Any]? = try? await mgr.getUserValves(id: id)
                (fetchedSpec, keyOrder) = try await specTask
                fetchedValues = await valuesTask ?? [:]
            case .function(let id):
                guard let mgr = functionsManager else { isLoading = false; return }
                async let specTask = mgr.getUserValvesSpecWithOrder(id: id)
                async let valuesTask: [String: Any]? = try? await mgr.getUserValves(id: id)
                (fetchedSpec, keyOrder) = try await specTask
                fetchedValues = await valuesTask ?? [:]
            }

            // Check cancellation before mutating state
            try Task.checkCancellation()

            spec = fetchedSpec
            values = fetchedValues
            specKeyOrder = keyOrder.isEmpty ? nil : keyOrder

            let props = fetchedSpec["properties"] as? [String: Any] ?? [:]
            for key in props.keys {
                let propSchema = props[key] as? [String: Any] ?? [:]
                let type = propSchema["type"] as? String ?? "string"
                if let v = fetchedValues[key] {
                    editValues[key] = arrayToDisplayString(v, type: type, schema: propSchema)
                } else {
                    defaultKeys.insert(key)
                    if let defVal = propSchema["default"] {
                        editValues[key] = arrayToDisplayString(defVal, type: type, schema: propSchema)
                    } else {
                        editValues[key] = ""
                    }
                }
            }
        } catch is CancellationError {
            // Task cancelled (e.g. user changed selection) — not an error
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Debounce-Save (500ms, matching OWUI)

    private func scheduleDebounce() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
        isSaving = true
        var payload: [String: Any] = [:]
        let props = spec["properties"] as? [String: Any] ?? [:]
        for key in propertyKeys {
            if defaultKeys.contains(key) {
                // Send null only if there was a previously saved value to clear
                if values[key] != nil { payload[key] = NSNull() }
                continue
            }
            let schema = props[key] as? [String: Any] ?? [:]
            let type = schema["type"] as? String ?? "string"
            let raw = editValues[key] ?? ""
            switch type {
            case "integer": payload[key] = Int(raw) ?? 0
            case "number":  payload[key] = Double(raw) ?? 0.0
            case "boolean": payload[key] = raw == "true" || raw == "1"
            case "array":
                // OWUI converts comma-string back to array on save
                let arr = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                payload[key] = arr
            default:        payload[key] = raw
            }
        }

        // Always send the save (even if payload is empty) to keep server state in sync
        // This matches OWUI behaviour which always calls updateUserValvesById
        do {
            switch kind {
            case .tool(let id):
                guard let mgr = toolsManager else { break }
                let updated = try await mgr.updateUserValves(id: id, values: payload)
                values = updated
            case .function(let id):
                guard let mgr = functionsManager else { break }
                let updated = try await mgr.updateUserValves(id: id, values: payload)
                values = updated
            }
        } catch {
            // Non-critical — silently ignore autosave failures
        }
        isSaving = false
    }
}
