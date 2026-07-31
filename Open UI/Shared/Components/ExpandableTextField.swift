import SwiftUI

// MARK: - ExpandableTextField
//
// A simple multiline text input with a fixed height —
// always ready to type, no swipe or gesture required.
//
// The `isMultiline` flag makes the field taller (for prompt templates).
//
// Usage:
//   ExpandableTextField(
//       text: $viewModel.someField,
//       placeholder: "Enter value…",
//       label: "Field Label"
//   )

struct ExpandableTextField: View {
    @Binding var text: String
    var placeholder: String = ""
    var label: String? = nil
    var keyboardType: UIKeyboardType = .default
    /// When true the field uses a taller height (for prompt templates).
    var isMultiline: Bool = false
    /// Unused — kept for API compatibility.
    var minExpandedHeight: CGFloat = 120
    /// Unused — kept for API compatibility.
    var maxExpandedHeight: CGFloat = 320

    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool

    private var fieldHeight: CGFloat { isMultiline ? 140 : 80 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
            }

            ZStack(alignment: .topLeading) {
                // Background + border
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.surfaceContainer.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isFocused
                                    ? theme.brandPrimary.opacity(0.45)
                                    : theme.inputBorder.opacity(0.3),
                                lineWidth: isFocused ? 1.0 : 0.5
                            )
                    )
                    .animation(.easeInOut(duration: 0.15), value: isFocused)

                // Placeholder
                if text.isEmpty {
                    Text(placeholder)
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }

                // TextEditor — always visible, always editable
                TextEditor(text: $text)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    .focused($isFocused)
            }
            .frame(height: fieldHeight)
            .clipped()
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        ExpandableTextField(
            text: .constant(""),
            placeholder: "Enter a watermark…",
            label: "Response Watermark"
        )

        ExpandableTextField(
            text: .constant("You are a helpful assistant. Reply concisely."),
            placeholder: "Enter prompt…",
            label: "System Prompt",
            isMultiline: true
        )
    }
    .padding()
}
