import SwiftUI
import UIKit

// MARK: - Emoji Picker Sheet (legacy — used by non-channel views)

/// Shows the native iOS emoji keyboard in a bottom sheet.
/// When the user taps an emoji, it fires `onEmojiSelected` and dismisses.
struct EmojiPickerSheet: View {
    let onEmojiSelected: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Pick a Reaction")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 22)
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.sm)
            
            // Native emoji keyboard via UITextField
            EmojiKeyboardView { emoji in
                onEmojiSelected(emoji)
                dismiss()
            }
            .frame(maxWidth: .infinity)
        }
        .background(theme.background)
    }
}

// MARK: - Inline Emoji Keyboard Host

/// A zero-height overlay that hosts a hidden EmojiTextField.
/// When `isActive` is set to true, the emoji keyboard slides up natively
/// (no sheet, no black background). The chat remains fully visible behind it.
///
/// Usage:
/// ```
/// .overlay { InlineEmojiKeyboard(isActive: $showEmoji) { emoji in … } }
/// ```
struct InlineEmojiKeyboard: UIViewRepresentable {
    @Binding var isActive: Bool
    let onEmojiSelected: (String) -> Void
    
    func makeUIView(context: Context) -> InlineEmojiContainer {
        let container = InlineEmojiContainer()
        container.coordinator = context.coordinator
        container.textField.delegate = context.coordinator
        // Invisible — sits at the bottom of the view, zero visual footprint
        container.translatesAutoresizingMaskIntoConstraints = false
        return container
    }
    
    func updateUIView(_ uiView: InlineEmojiContainer, context: Context) {
        if isActive {
            if !uiView.textField.isFirstResponder {
                uiView.textField.becomeFirstResponder()
            }
        } else {
            if uiView.textField.isFirstResponder {
                uiView.textField.resignFirstResponder()
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: $isActive, onEmojiSelected: onEmojiSelected)
    }
    
    class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var isActive: Bool
        let onEmojiSelected: (String) -> Void
        
        init(isActive: Binding<Bool>, onEmojiSelected: @escaping (String) -> Void) {
            self._isActive = isActive
            self.onEmojiSelected = onEmojiSelected
        }
        
        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if !string.isEmpty && string.containsEmoji {
                onEmojiSelected(string)
                textField.text = ""
                return false
            }
            // Block non-emoji input
            return false
        }
        
        func textFieldDidEndEditing(_ textField: UITextField) {
            // Sync state when keyboard is dismissed via swipe/tap outside
            DispatchQueue.main.async { [weak self] in
                self?.isActive = false
            }
        }
    }
}

/// Container UIView that holds the hidden EmojiTextField with zero visible height.
class InlineEmojiContainer: UIView {
    let textField = EmojiTextField()
    weak var coordinator: InlineEmojiKeyboard.Coordinator?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupTextField()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTextField()
    }
    
    private func setupTextField() {
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.backgroundColor = .clear
        textField.tintColor = .clear
        textField.textColor = .clear
        textField.font = .systemFont(ofSize: 1)
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor),
            textField.topAnchor.constraint(equalTo: topAnchor),
            textField.heightAnchor.constraint(equalToConstant: 0),
            // Container itself is zero height
            heightAnchor.constraint(equalToConstant: 0),
        ])
        clipsToBounds = true
    }
    
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 0)
    }
}

// MARK: - Emoji Keyboard View (UIViewRepresentable) — used by EmojiPickerSheet

/// Wraps a UITextField that auto-shows the iOS emoji keyboard.
/// Intercepts text input to capture emoji selections.
struct EmojiKeyboardView: UIViewRepresentable {
    let onEmojiSelected: (String) -> Void
    
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let textField = EmojiTextField()
        textField.delegate = context.coordinator
        textField.translatesAutoresizingMaskIntoConstraints = false
        // Make it invisible but interactive
        textField.backgroundColor = .clear
        textField.tintColor = .clear
        textField.textColor = .clear
        textField.font = .systemFont(ofSize: 1)
        
        container.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textField.topAnchor.constraint(equalTo: container.topAnchor),
            textField.heightAnchor.constraint(equalToConstant: 1),
        ])
        
        // Auto-focus to show keyboard
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            textField.becomeFirstResponder()
        }
        
        return container
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onEmojiSelected: onEmojiSelected)
    }
    
    class Coordinator: NSObject, UITextFieldDelegate {
        let onEmojiSelected: (String) -> Void
        
        init(onEmojiSelected: @escaping (String) -> Void) {
            self.onEmojiSelected = onEmojiSelected
        }
        
        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if !string.isEmpty && string.containsEmoji {
                onEmojiSelected(string)
                textField.text = ""
                return false
            }
            // Block non-emoji input
            return false
        }
    }
}

// MARK: - Emoji Text Field (forces emoji keyboard)

/// A UITextField subclass that overrides textInputMode to prefer the emoji keyboard.
class EmojiTextField: UITextField {
    override var textInputMode: UITextInputMode? {
        // Find and return the emoji input mode
        for mode in UITextInputMode.activeInputModes {
            if mode.primaryLanguage == "emoji" {
                return mode
            }
        }
        return super.textInputMode
    }
    
    override var textInputContextIdentifier: String? {
        // Return non-nil to force the emoji keyboard to stay
        return ""
    }
}

// MARK: - String Emoji Detection

extension String {
    var containsEmoji: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.isEmoji && (scalar.properties.isEmojiPresentation || scalar.value > 0x238C)
        }
    }
}
