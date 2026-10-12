import SwiftUI

// MARK: - Enroll + code sections

extension MFAChallengeForm {
    @ViewBuilder
    var enrollSection: some View {
        if let setup {
            VStack(spacing: Spacing.md) {
                if let uri = setup.otpauthURI(account: accountLabel.isEmpty ? "Open Relay" : accountLabel) {
                    MFAQRCodeView(uri: uri)
                        .frame(width: 180, height: 180)
                        .frame(maxWidth: .infinity)

                    Button {
                        openURL(uri)
                    } label: {
                        Label("Open in Authenticator App", systemImage: "key.viewfinder")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.brandPrimary)
                    }
                }

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Or enter the key manually")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                    HStack {
                        Text(setup.manualKey)
                            .scaledFont(size: 13, weight: .medium, design: .monospaced)
                            .foregroundStyle(theme.textPrimary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: Spacing.sm)
                        Button {
                            UIPasteboard.general.string = setup.manualKey
                            keyCopied = true
                            Haptics.play(.light)
                        } label: {
                            Image(systemName: keyCopied ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(theme.brandPrimary)
                        }
                        .accessibilityLabel(Text("Copy setup key"))
                    }
                    .padding(Spacing.md)
                    .background(theme.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                }
            }
        } else if busy {
            HStack(spacing: Spacing.sm) {
                ProgressView()
                Text("Preparing your authenticator…")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.lg)
        } else {
            if let error { AuthErrorBanner(message: error) }
            Button("Retry setup") { Task { await loadSetupIfNeeded() } }
                .foregroundStyle(theme.brandPrimary)
        }
    }

    @ViewBuilder
    var codeSection: some View {
        let numeric = !current.isRecover && !useRecovery
        MFACodeField(
            label: current.isRecover
                ? String(localized: "Recovery token")
                : (useRecovery ? String(localized: "Recovery code") : String(localized: "Authenticator code")),
            text: $code,
            isNumeric: numeric,
            onSubmit: { Task { await submit() } }
        )
        .id(numeric)

        if let error {
            AuthErrorBanner(message: error)
                .shakeOnError(trigger: shake)
        }

        AuthPrimaryButton(
            title: current.isRecover ? String(localized: "Continue") : String(localized: "Verify"),
            icon: busy ? nil : "checkmark.shield",
            isLoading: busy,
            isDisabled: code.trimmingCharacters(in: .whitespaces).isEmpty
        ) {
            Task { await submit() }
        }

        if current.nextStep == "verify" {
            Button {
                useRecovery.toggle()
                code = ""
                error = nil
            } label: {
                Text(useRecovery ? "Use your authenticator app" : "Use a recovery code")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
