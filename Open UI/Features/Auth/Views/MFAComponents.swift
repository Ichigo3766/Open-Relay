import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - QR Code

/// Renders an `otpauth://` provisioning URI as a crisp QR image.
struct MFAQRCodeView: View {
    let uri: URL

    var body: some View {
        if let image = Self.makeImage(uri.absoluteString) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(10)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .accessibilityLabel(Text("Authenticator setup QR code"))
        }
    }

    private static func makeImage(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Code Field

/// One-time-code input: numeric 6-digit authenticator codes, or free text for
/// recovery codes / operator reset tokens.
struct MFACodeField: View {
    let label: String
    @Binding var text: String
    var isNumeric: Bool = true
    var onSubmit: () -> Void = {}

    @FocusState private var focused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(label)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textTertiary)
            TextField(isNumeric ? "123456" : "", text: $text)
                .focused($focused)
                .keyboardType(isNumeric ? .numberPad : .asciiCapable)
                .textContentType(isNumeric ? .oneTimeCode : nil)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .scaledFont(size: isNumeric ? 24 : 16, weight: .semibold, design: .monospaced)
                .multilineTextAlignment(isNumeric ? .center : .leading)
                .padding(Spacing.md)
                .background(theme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .onChange(of: text) { _, newValue in
                    guard isNumeric else { return }
                    let digits = String(newValue.filter(\.isNumber).prefix(6))
                    if digits != newValue { text = digits }
                    if digits.count == 6 { onSubmit() }
                }
                .onSubmit(onSubmit)
        }
        .onAppear { focused = true }
    }
}

// MARK: - Recovery Codes

/// Shows freshly issued recovery codes. The user must confirm they saved them.
struct MFARecoveryCodesView: View {
    let codes: [String]
    let continueTitle: String
    let onContinue: () -> Void

    @State private var saved = false
    @State private var copied = false
    @Environment(\.theme) private var theme

    private var codesText: String { codes.joined(separator: "\n") + "\n" }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Save your recovery codes")
                    .scaledFont(size: 17, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Text("Each code works once. Save them somewhere safe; they will not be shown again.")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.sm) {
                ForEach(codes, id: \.self) { code in
                    Text(code)
                        .scaledFont(size: 14, weight: .medium, design: .monospaced)
                        .foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.xs)
                }
            }
            .padding(Spacing.md)
            .background(theme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))

            HStack(spacing: Spacing.md) {
                Button {
                    UIPasteboard.general.string = codesText
                    copied = true
                    Haptics.play(.light)
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .scaledFont(size: 14, weight: .medium)
                }
                ShareLink(item: codesText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .scaledFont(size: 14, weight: .medium)
                }
            }
            .foregroundStyle(theme.brandPrimary)

            Toggle(isOn: $saved) {
                Text("I have saved my recovery codes")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
            }
            .tint(theme.brandPrimary)

            AuthPrimaryButton(title: continueTitle, icon: "arrow.right", isDisabled: !saved) {
                onContinue()
            }
        }
    }
}
