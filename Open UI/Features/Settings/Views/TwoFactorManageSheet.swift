import SwiftUI

/// Verify a fresh code, then replace the authenticator or issue new recovery codes.
/// Both actions sign every device out, so the app returns to sign-in afterwards.
struct TwoFactorManageSheet: View {
    let accountLabel: String

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var code = ""
    @State private var useRecovery = false
    @State private var busy = false
    @State private var error: String?
    @State private var needsReauth = false
    @State private var replaceChallenge: MfaChallenge?
    @State private var newCodes: [String] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    if !newCodes.isEmpty {
                        MFARecoveryCodesView(codes: newCodes, continueTitle: String(localized: "Sign in again")) {
                            signInAgain()
                        }
                    } else if let replaceChallenge {
                        MFAChallengeForm(
                            client: dependencies.apiClient,
                            initialChallenge: replaceChallenge,
                            accountLabel: accountLabel,
                            onComplete: { _ in signInAgain() },
                            onChallengeExpired: {
                                self.replaceChallenge = nil
                                error = String(localized: "This step expired. Enter a fresh code to start again.")
                            }
                        )
                    } else {
                        verifySection
                    }
                }
                .padding(Spacing.screenPadding)
            }
            .background(theme.background)
            .navigationTitle("Two-Factor Sign-In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(!newCodes.isEmpty || replaceChallenge != nil)
    }

    @ViewBuilder
    private var verifySection: some View {
        Text("Verify with a fresh code. Changes sign out all devices.")
            .scaledFont(size: 13)
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

        MFACodeField(
            label: useRecovery ? String(localized: "Recovery code") : String(localized: "Authenticator code"),
            text: $code,
            isNumeric: !useRecovery
        )
        .id(useRecovery)

        Toggle(isOn: $useRecovery) {
            Text("Use a recovery code").scaledFont(size: 14).foregroundStyle(theme.textPrimary)
        }
        .tint(theme.brandPrimary)
        .onChange(of: useRecovery) { _, _ in code = "" }

        if let error { AuthErrorBanner(message: error) }

        if needsReauth {
            AuthPrimaryButton(title: String(localized: "Sign in again"), icon: "person.crop.circle") {
                signInAgain()
            }
        } else {
            AuthPrimaryButton(
                title: String(localized: "Replace authenticator"),
                icon: busy ? nil : "arrow.triangle.2.circlepath",
                isLoading: busy,
                isDisabled: code.isEmpty
            ) {
                Task { await manage(replace: true) }
            }

            Button {
                Task { await manage(replace: false) }
            } label: {
                Text("Generate recovery codes")
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
                    .frame(maxWidth: .infinity)
            }
            .disabled(busy || code.isEmpty)
        }
    }

    private func manage(replace: Bool) async {
        guard let client = dependencies.apiClient, !busy else { return }
        busy = true
        error = nil
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if replace {
                replaceChallenge = try await client.mfaReplace(code: trimmed, recovery: useRecovery)
            } else {
                newCodes = try await client.mfaRegenerateRecoveryCodes(code: trimmed, recovery: useRecovery)
            }
            code = ""
        } catch {
            if case .httpError(_, let message, _) = APIError.from(error), message == "reauthentication_required" {
                needsReauth = true
            }
            self.error = APIClient.mfaErrorMessage(error)
            code = ""
            Haptics.notify(.error)
        }
        busy = false
    }

    /// Every session (including this one) was revoked — sign in fresh.
    private func signInAgain() {
        dismiss()
        Task { await dependencies.authViewModel.signOut() }
    }
}
