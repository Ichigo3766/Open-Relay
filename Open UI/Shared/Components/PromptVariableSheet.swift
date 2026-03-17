import SwiftUI

// MARK: - Prompt Variable Sheet

/// A modal sheet that presents a form for filling in prompt template variables.
///
/// Shown when the user selects a prompt that contains custom input variables
/// (e.g., `{{topic}}`, `{{priority | select:options=["High","Low"]}}`).
///
/// Supports all Open WebUI variable types: text, textarea, select, number,
/// checkbox, date, datetime-local, color, email, range, tel, time, url.
///
/// Required fields are marked with an asterisk and validated before submission.
struct PromptVariableSheet: View {
    let promptName: String
    let variables: [PromptVariable]
    let onSave: ([String: String]) -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var showValidationErrors = false

    /// Whether all required fields have been filled.
    private var isValid: Bool {
        for variable in variables where variable.isRequired {
            let value = values[variable.name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty { return false }
        }
        return true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    // Prompt info header
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "text.book.closed.fill")
                            .scaledFont(size: 18)
                            .foregroundStyle(theme.brandPrimary)
                        Text(promptName)
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                    }
                    .padding(.bottom, Spacing.xs)

                    Text("Fill in the values below. Fields marked with * are required.")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)

                    // Variable form fields
                    ForEach(variables) { variable in
                        variableField(variable)
                    }
                }
                .padding(Spacing.lg)
            }
            .background(theme.background)
            .navigationTitle("Input Variables")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if isValid {
                            onSave(values)
                            dismiss()
                        } else {
                            showValidationErrors = true
                            Haptics.notify(.warning)
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            initializeDefaults()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Pre-populates fields with default values from variable definitions.
    private func initializeDefaults() {
        for variable in variables {
            if let defaultValue = variable.defaultValue, !defaultValue.isEmpty {
                values[variable.name] = defaultValue
            }
        }
    }

    // MARK: - Variable Field Builder

    @ViewBuilder
    private func variableField(_ variable: PromptVariable) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Label
            HStack(spacing: 3) {
                Text(variable.displayName)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                if variable.isRequired {
                    Text("*")
                        .scaledFont(size: 13, weight: .bold)
                        .foregroundStyle(theme.error)
                }
            }

            // Input field based on type
            switch variable.type {
            case .text, .email, .tel, .url:
                textInput(variable)
            case .textarea:
                textareaInput(variable)
            case .select:
                selectInput(variable)
            case .number:
                numberInput(variable)
            case .checkbox:
                checkboxInput(variable)
            case .date:
                dateInput(variable)
            case .datetimeLocal:
                datetimeInput(variable)
            case .time:
                timeInput(variable)
            case .color:
                colorInput(variable)
            case .range:
                rangeInput(variable)
            case .month:
                textInput(variable) // Month picker is text on iOS
            case .map:
                textInput(variable) // Map renders as text coordinates on iOS
            }

            // Validation error
            if showValidationErrors && variable.isRequired {
                let value = values[variable.name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if value.isEmpty {
                    Text("This field is required")
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.error)
                }
            }
        }
    }

    // MARK: - Text Input

    private func textInput(_ variable: PromptVariable) -> some View {
        let binding = Binding<String>(
            get: { values[variable.name] ?? "" },
            set: { values[variable.name] = $0 }
        )

        return TextField(
            variable.placeholder ?? variable.displayName,
            text: binding
        )
        .textFieldStyle(.plain)
        .scaledFont(size: 14)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    showValidationErrors && variable.isRequired && (values[variable.name] ?? "").isEmpty
                        ? theme.error.opacity(0.6)
                        : theme.cardBorder.opacity(0.4),
                    lineWidth: 0.5
                )
        )
        .keyboardType(keyboardType(for: variable.type))
        .textContentType(contentType(for: variable.type))
        .autocapitalization(variable.type == .email || variable.type == .url ? .none : .sentences)
    }

    // MARK: - Textarea Input

    private func textareaInput(_ variable: PromptVariable) -> some View {
        let binding = Binding<String>(
            get: { values[variable.name] ?? "" },
            set: { values[variable.name] = $0 }
        )

        return TextEditor(text: binding)
            .scaledFont(size: 14)
            .frame(minHeight: 100, maxHeight: 200)
            .padding(8)
            .scrollContentBackground(.hidden)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.inputBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
            )
            .overlay(alignment: .topLeading) {
                if (values[variable.name] ?? "").isEmpty {
                    Text(variable.placeholder ?? variable.displayName)
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textTertiary.opacity(0.5))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: - Select Input

    private func selectInput(_ variable: PromptVariable) -> some View {
        let binding = Binding<String>(
            get: { values[variable.name] ?? "" },
            set: { values[variable.name] = $0 }
        )

        return Menu {
            if !variable.isRequired {
                Button("None") {
                    values[variable.name] = ""
                }
            }
            ForEach(variable.options ?? [], id: \.self) { option in
                Button(option) {
                    values[variable.name] = option
                }
            }
        } label: {
            HStack {
                Text(binding.wrappedValue.isEmpty
                     ? (variable.placeholder ?? "Select…")
                     : binding.wrappedValue)
                    .scaledFont(size: 14)
                    .foregroundStyle(
                        binding.wrappedValue.isEmpty
                            ? theme.textTertiary.opacity(0.5)
                            : theme.textPrimary
                    )
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.inputBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Number Input

    private func numberInput(_ variable: PromptVariable) -> some View {
        let binding = Binding<String>(
            get: { values[variable.name] ?? "" },
            set: { values[variable.name] = $0 }
        )

        return TextField(
            variable.placeholder ?? "Enter number",
            text: binding
        )
        .textFieldStyle(.plain)
        .scaledFont(size: 14)
        .keyboardType(.decimalPad)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
        )
    }

    // MARK: - Checkbox Input

    private func checkboxInput(_ variable: PromptVariable) -> some View {
        let isOn = Binding<Bool>(
            get: { values[variable.name] == "true" },
            set: { values[variable.name] = $0 ? "true" : "false" }
        )

        return Toggle(isOn: isOn) {
            Text(variable.label ?? variable.displayName)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textPrimary)
        }
        .tint(theme.brandPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
        )
    }

    // MARK: - Date Input

    private func dateInput(_ variable: PromptVariable) -> some View {
        let binding = Binding<Date>(
            get: {
                if let str = values[variable.name], !str.isEmpty {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    return formatter.date(from: str) ?? Date()
                }
                return Date()
            },
            set: { date in
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                values[variable.name] = formatter.string(from: date)
            }
        )

        return DatePicker(
            variable.displayName,
            selection: binding,
            displayedComponents: [.date]
        )
        .datePickerStyle(.compact)
        .scaledFont(size: 14)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
        )
        .labelsHidden()
    }

    // MARK: - Datetime Input

    private func datetimeInput(_ variable: PromptVariable) -> some View {
        let binding = Binding<Date>(
            get: {
                if let str = values[variable.name], !str.isEmpty {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
                    return formatter.date(from: str) ?? Date()
                }
                return Date()
            },
            set: { date in
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
                values[variable.name] = formatter.string(from: date)
            }
        )

        return DatePicker(
            variable.displayName,
            selection: binding,
            displayedComponents: [.date, .hourAndMinute]
        )
        .datePickerStyle(.compact)
        .scaledFont(size: 14)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
        )
        .labelsHidden()
    }

    // MARK: - Time Input

    private func timeInput(_ variable: PromptVariable) -> some View {
        let binding = Binding<Date>(
            get: {
                if let str = values[variable.name], !str.isEmpty {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm"
                    return formatter.date(from: str) ?? Date()
                }
                return Date()
            },
            set: { date in
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                values[variable.name] = formatter.string(from: date)
            }
        )

        return DatePicker(
            variable.displayName,
            selection: binding,
            displayedComponents: [.hourAndMinute]
        )
        .datePickerStyle(.compact)
        .scaledFont(size: 14)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
        )
        .labelsHidden()
    }

    // MARK: - Color Input

    private func colorInput(_ variable: PromptVariable) -> some View {
        let binding = Binding<Color>(
            get: {
                if let hex = values[variable.name], !hex.isEmpty {
                    return Color(hex: hex)
                }
                return .blue
            },
            set: { color in
                values[variable.name] = color.toHex()
            }
        )

        return ColorPicker(
            variable.displayName,
            selection: binding
        )
        .scaledFont(size: 14)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
        )
    }

    // MARK: - Range Input

    private func rangeInput(_ variable: PromptVariable) -> some View {
        let minVal = Double(variable.min ?? "0") ?? 0
        let maxVal = Double(variable.max ?? "100") ?? 100
        let stepVal = Double(variable.step ?? "1") ?? 1
        let currentVal = Double(values[variable.name] ?? "\(minVal)") ?? minVal

        let binding = Binding<Double>(
            get: { currentVal },
            set: { values[variable.name] = String(Int($0)) }
        )

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Slider(value: binding, in: minVal...maxVal, step: stepVal)
                    .tint(theme.brandPrimary)
                Text("\(Int(currentVal))")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.textSecondary)
                    .frame(minWidth: 30)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
        )
    }

    // MARK: - Helpers

    private func keyboardType(for type: PromptVariable.VariableType) -> UIKeyboardType {
        switch type {
        case .email: return .emailAddress
        case .tel: return .phonePad
        case .url: return .URL
        case .number: return .decimalPad
        default: return .default
        }
    }

    private func contentType(for type: PromptVariable.VariableType) -> UITextContentType? {
        switch type {
        case .email: return .emailAddress
        case .tel: return .telephoneNumber
        case .url: return .URL
        default: return nil
        }
    }
}

// MARK: - Color Hex Helpers

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            r = 0; g = 0; b = 0
        }
        self.init(red: r, green: g, blue: b)
    }

    func toHex() -> String {
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else {
            return "#000000"
        }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
