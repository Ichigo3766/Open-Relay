import SwiftUI

/// `AuthPhase.mfaChallenge` — the authenticator step after a password, LDAP,
/// sign-up or native-SSO sign-in on servers with two-factor sign-in on.
struct MFAChallengeView: View {
    @Bindable var viewModel: AuthViewModel
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: Spacing.xl) {
                Spacer(minLength: Spacing.lg)

                AuthScreenHeader(
                    icon: "lock.shield",
                    title: String(localized: "Two-Factor Sign-In"),
                    subtitle: String(localized: "Your server requires an authenticator app.")
                )

                if let challenge = viewModel.mfaChallenge {
                    MFAChallengeForm(
                        client: dependencies.apiClient,
                        initialChallenge: challenge,
                        accountLabel: viewModel.mfaAccountLabel,
                        onComplete: { user in
                            guard let user else { return }
                            await viewModel.completeMFASignIn(user: user)
                        },
                        onChallengeChanged: { viewModel.updateMFAChallenge($0) },
                        onChallengeExpired: {
                            let message = String(localized: "This sign-in step expired. Please sign in again.")
                            viewModel.cancelMFA()
                            viewModel.errorMessage = message
                        }
                    )
                    .padding(Spacing.lg)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                            .strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.5)
                    )
                    .frame(maxWidth: 520)
                    .padding(.horizontal, Spacing.screenPadding)
                }

                Spacer(minLength: Spacing.xl)
            }
            .frame(maxWidth: .infinity)
        }
        .background(theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    viewModel.cancelMFA()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "chevron.left")
                            .scaledFont(size: 14, weight: .semibold)
                        Text("Back")
                            .scaledFont(size: 14)
                    }
                    .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .alert(
            "Save for \(viewModel.biometricTypeName)?",
            isPresented: $viewModel.showBiometricSavePrompt
        ) {
            Button("Save") {
                viewModel.saveBiometricCredentials(
                    email: viewModel.pendingBiometricEmail,
                    password: viewModel.pendingBiometricPassword
                )
                viewModel.proceedToAuthenticated()
            }
            Button("Not Now", role: .cancel) {
                viewModel.proceedToAuthenticated()
            }
        } message: {
            Text("Sign in faster next time with \(viewModel.biometricTypeName). You'll still confirm with your authenticator.")
        }
    }
}
