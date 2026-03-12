import SwiftUI

// MARK: - Password Strength Indicator

/// Animated password strength bar with color transitions.
private struct PasswordStrengthIndicator: View {
    let strength: Double
    @Environment(\.theme) private var theme

    private var strengthColor: Color {
        switch strength {
        case 0..<0.26: return theme.error
        case 0.26..<0.51: return theme.warning
        case 0.51..<0.76: return theme.info
        default: return theme.success
        }
    }

    private var strengthLabel: String {
        switch strength {
        case 0: return ""
        case 0..<0.26: return "Weak"
        case 0.26..<0.51: return "Fair"
        case 0.51..<0.76: return "Good"
        default: return "Strong"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Animated bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.divider)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(strengthColor)
                        .frame(width: geometry.size.width * strength)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: strength)
                }
            }
            .frame(height: 6)

            // Label
            if !strengthLabel.isEmpty {
                Text(strengthLabel)
                    .font(AppTypography.captionFont)
                    .foregroundStyle(strengthColor)
                    .animation(.easeOut(duration: 0.2), value: strengthLabel)
            }
        }
    }
}

// MARK: - Password Requirement Check

/// A single password requirement with animated check state.
private struct PasswordRequirement: View {
    let text: String
    let isMet: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: isMet ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(isMet ? theme.success : theme.textTertiary)
                .contentTransition(.symbolEffect(.replace))
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isMet)

            Text(text)
                .font(AppTypography.captionFont)
                .foregroundStyle(isMet ? theme.textSecondary : theme.textTertiary)
                .animation(.easeOut(duration: 0.2), value: isMet)
        }
    }
}

// MARK: - Sign Up View

/// Modern sign-up view with animated validation and password strength.
struct SignUpView: View {
    @Bindable var viewModel: AuthViewModel
    @Environment(\.theme) private var theme
    @State private var formAppeared = false
    @State private var shakeCount = 0
    @State private var showRequirements = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: Spacing.lg) {
                Spacer(minLength: Spacing.md)

                // Header
                signUpHeader

                // Form card
                VStack(spacing: Spacing.lg) {
                    // Name field
                    ModernTextField(
                        label: "Full Name",
                        placeholder: "What should we call you?",
                        text: $viewModel.signUpName,
                        textContentType: .name
                    )

                    // Email field
                    ModernTextField(
                        label: "Email",
                        placeholder: "you@example.com",
                        text: $viewModel.signUpEmail,
                        keyboardType: .emailAddress,
                        textContentType: .emailAddress
                    )

                    // Email validation hint
                    if !viewModel.signUpEmail.isEmpty && !viewModel.isSignUpEmailValid {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 12))
                            Text("Please enter a valid email address")
                                .font(AppTypography.captionFont)
                        }
                        .foregroundStyle(theme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // Password field
                    VStack(spacing: Spacing.sm) {
                        ModernTextField(
                            label: "Password",
                            placeholder: "Create a password",
                            text: $viewModel.signUpPassword,
                            isSecure: true,
                            textContentType: .newPassword
                        )

                        // Strength indicator
                        if !viewModel.signUpPassword.isEmpty {
                            PasswordStrengthIndicator(strength: viewModel.passwordStrength)
                                .transition(.opacity.combined(with: .move(edge: .top)))

                            // Requirements checklist
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                PasswordRequirement(
                                    text: "At least 8 characters",
                                    isMet: viewModel.signUpPassword.count >= 8
                                )
                                PasswordRequirement(
                                    text: "One uppercase letter",
                                    isMet: viewModel.passwordHasUppercase
                                )
                                PasswordRequirement(
                                    text: "One lowercase letter",
                                    isMet: viewModel.passwordHasLowercase
                                )
                                PasswordRequirement(
                                    text: "One number",
                                    isMet: viewModel.passwordHasNumber
                                )
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    // Confirm password field
                    VStack(spacing: Spacing.xs) {
                        ModernTextField(
                            label: "Confirm Password",
                            placeholder: "Re-enter your password",
                            text: $viewModel.signUpConfirmPassword,
                            isSecure: true,
                            textContentType: .newPassword,
                            onSubmit: {
                                if viewModel.isSignUpFormValid {
                                    Task { await viewModel.signUp() }
                                }
                            }
                        )

                        // Match indicator
                        if !viewModel.signUpConfirmPassword.isEmpty {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: viewModel.doPasswordsMatch ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .contentTransition(.symbolEffect(.replace))
                                Text(viewModel.doPasswordsMatch ? "Passwords match" : "Passwords don't match")
                                    .font(AppTypography.captionFont)
                            }
                            .foregroundStyle(viewModel.doPasswordsMatch ? theme.success : theme.error)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.doPasswordsMatch)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    // Error message
                    if let error = viewModel.errorMessage {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(theme.error)
                                .font(.system(size: 14))
                            Text(error)
                                .font(AppTypography.captionFont)
                                .foregroundStyle(theme.error)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.md)
                        .background(theme.errorBackground)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                        .shakeOnError(trigger: shakeCount)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.95).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }

                    // Create account button
                    AuthPrimaryButton(
                        title: "Create Account",
                        icon: viewModel.isSigningUp ? nil : "person.badge.plus",
                        isLoading: viewModel.isSigningUp,
                        isDisabled: !viewModel.isSignUpFormValid
                    ) {
                        Task {
                            await viewModel.signUp()
                            if viewModel.errorMessage != nil {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                                    shakeCount += 1
                                }
                            }
                        }
                    }

                    // Already have account link
                    HStack(spacing: Spacing.xs) {
                        Text("Already have an account?")
                            .font(AppTypography.bodySmallFont)
                            .foregroundStyle(theme.textTertiary)

                        Button {
                            withAnimation(MicroAnimation.gentle) {
                                viewModel.goToPhase(.credentialLogin)
                            }
                        } label: {
                            Text("Sign In")
                                .font(AppTypography.labelMediumFont)
                                .foregroundStyle(theme.brandPrimary)
                        }
                    }
                    .padding(.top, Spacing.xs)
                }
                .padding(Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                        .strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.5)
                )
                .padding(.horizontal, Spacing.screenPadding)
                .opacity(formAppeared ? 1 : 0)
                .offset(y: formAppeared ? 0 : 20)

                Spacer(minLength: Spacing.xl)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.signUpPassword.isEmpty)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.signUpConfirmPassword.isEmpty)
        }
        .background(theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    viewModel.goBack()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Back")
                            .font(AppTypography.bodySmallFont)
                    }
                    .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2)) {
                formAppeared = true
            }
        }
    }

    // MARK: - Header

    private var signUpHeader: some View {
        VStack(spacing: Spacing.sm) {
            ZStack {
                Circle()
                    .fill(theme.brandPrimary.opacity(0.1))
                    .frame(width: 80, height: 80)
                    .scaleEffect(formAppeared ? 1.0 : 0.6)

                Image(systemName: "person.badge.plus")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(theme.brandPrimary)
                    .scaleEffect(formAppeared ? 1.0 : 0.5)
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.1), value: formAppeared)

            Text("Create Account")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .opacity(formAppeared ? 1 : 0)
                .offset(y: formAppeared ? 0 : 8)

            Text("Join \(viewModel.serverName)")
                .font(AppTypography.bodySmallFont)
                .foregroundStyle(theme.textSecondary)
                .opacity(formAppeared ? 1 : 0)
                .offset(y: formAppeared ? 0 : 8)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.15), value: formAppeared)
    }
}
