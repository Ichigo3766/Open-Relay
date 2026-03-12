import SwiftUI

/// Shown after sign-up when the user's account is pending admin approval.
struct PendingApprovalView: View {
    @Bindable var viewModel: AuthViewModel
    @Environment(\.theme) private var theme
    @State private var appeared = false
    @State private var isChecking = false
    @State private var pulseAnimation = false
    @State private var checkResult: CheckResult?

    private enum CheckResult {
        case approved
        case stillPending
    }

    private var userName: String {
        viewModel.currentUser?.name ?? viewModel.currentUser?.username ?? "there"
    }

    var body: some View {
        ZStack {
            // Subtle animated background
            theme.background.ignoresSafeArea()

            // Faint orb for visual interest
            Circle()
                .fill(theme.warning.opacity(0.06))
                .frame(width: 280, height: 280)
                .blur(radius: 60)
                .offset(y: -100)
                .scaleEffect(pulseAnimation ? 1.1 : 0.95)
                .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: pulseAnimation)

            ScrollView(showsIndicators: false) {
                VStack(spacing: Spacing.xl) {
                    Spacer(minLength: 80)

                    // Icon
                    ZStack {
                        Circle()
                            .fill(theme.warning.opacity(0.12))
                            .frame(width: 120, height: 120)
                            .scaleEffect(appeared ? 1.0 : 0.5)

                        Circle()
                            .fill(theme.warning.opacity(0.08))
                            .frame(width: 90, height: 90)

                        Image(systemName: "clock.badge.checkmark")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(theme.warning)
                            .scaleEffect(appeared ? 1.0 : 0.4)
                    }
                    .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.1), value: appeared)

                    // Title & message
                    VStack(spacing: Spacing.md) {
                        Text("Account Pending")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.textPrimary)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 10)
                            .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.2), value: appeared)

                        Text("Hi \(userName)! Your account has been created and is awaiting approval from an administrator.")
                            .font(AppTypography.bodyMediumFont)
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Spacing.md)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 10)
                            .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.3), value: appeared)
                    }

                    // Info card
                    VStack(spacing: Spacing.md) {
                        infoRow(
                            icon: "person.badge.shield.checkmark",
                            iconColor: theme.info,
                            title: "Admin Review",
                            subtitle: "An administrator needs to verify and approve your account before you can sign in."
                        )

                        Divider()
                            .background(theme.divider)

                        infoRow(
                            icon: "bell.badge",
                            iconColor: theme.success,
                            title: "Check Back Later",
                            subtitle: "Once approved, tap the button below to check your status and get started."
                        )
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
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.4), value: appeared)

                    // Error / success message
                    if let error = viewModel.errorMessage {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(theme.warning)
                                .font(.system(size: 14))
                            Text(error)
                                .font(AppTypography.captionFont)
                                .foregroundStyle(theme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.md)
                        .background(theme.warningBackground)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                        .padding(.horizontal, Spacing.screenPadding)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.95).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }

                    // Check approval button
                    VStack(spacing: Spacing.md) {
                        AuthPrimaryButton(
                            title: isChecking ? "Checking..." : "Check Approval Status",
                            icon: isChecking ? nil : "arrow.clockwise",
                            isLoading: isChecking
                        ) {
                            Task {
                                isChecking = true
                                await viewModel.checkApprovalStatus()
                                isChecking = false
                            }
                        }
                        .padding(.horizontal, Spacing.screenPadding)

                        // Sign out / use different account
                        Button {
                            Task { await viewModel.signOut() }
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "arrow.left.circle")
                                    .font(.system(size: 14))
                                Text("Use a different account")
                                    .font(AppTypography.bodySmallFont)
                            }
                            .foregroundStyle(theme.textTertiary)
                        }
                    }
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.5), value: appeared)

                    Spacer(minLength: Spacing.xl)
                }
            }
        }
        .onAppear {
            appeared = true
            pulseAnimation = true
        }
    }

    // MARK: - Info Row

    private func infoRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 36, height: 36)
                .background(iconColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(AppTypography.labelLargeFont)
                    .foregroundStyle(theme.textPrimary)

                Text(subtitle)
                    .font(AppTypography.captionFont)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }
}
