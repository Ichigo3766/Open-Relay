import SwiftUI

/// Onboarding sheet shown to first-time users after login — immersive full-screen design.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var currentPage = 0
    @State private var appeared = false

    let userName: String
    let onComplete: () -> Void

    private var pages: [OnboardingPage] {
        [
            OnboardingPage(
                icon: "sparkles",
                iconColor: .purple,
                title: "Welcome, \(userName)!",
                subtitle: "Your AI conversations, beautifully native.",
                features: [
                    OnboardingFeature(icon: "bubble.left.and.bubble.right.fill", text: "Chat with any AI model"),
                    OnboardingFeature(icon: "bolt.fill", text: "Fast, responsive native experience"),
                    OnboardingFeature(icon: "iphone", text: "Built for iOS from the ground up")
                ]
            ),
            OnboardingPage(
                icon: "paperclip.circle.fill",
                iconColor: .blue,
                title: "Attach & Share",
                subtitle: "Bring rich context to your conversations.",
                features: [
                    OnboardingFeature(icon: "doc.fill", text: "Attach files, images, documents"),
                    OnboardingFeature(icon: "square.and.arrow.up", text: "Share from any app directly"),
                    OnboardingFeature(icon: "photo.fill", text: "Multimodal vision support")
                ]
            ),
            OnboardingPage(
                icon: "waveform.circle.fill",
                iconColor: .green,
                title: "Voice & Audio",
                subtitle: "Speak naturally with AI.",
                features: [
                    OnboardingFeature(icon: "mic.fill", text: "Voice input for hands-free use"),
                    OnboardingFeature(icon: "speaker.wave.2.fill", text: "Natural text-to-speech responses"),
                    OnboardingFeature(icon: "phone.fill", text: "Voice call mode for conversation")
                ]
            ),
            OnboardingPage(
                icon: "rocket.fill",
                iconColor: .orange,
                title: "You're All Set",
                subtitle: "Start your first conversation.",
                features: [
                    OnboardingFeature(icon: "hand.draw.fill", text: "Swipe to access chat history"),
                    OnboardingFeature(icon: "plus.circle.fill", text: "Tap + to start a new conversation"),
                    OnboardingFeature(icon: "gearshape.fill", text: "Customize in Settings")
                ]
            )
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(theme.textTertiary.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, Spacing.md)

            // Page content
            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    pageContent(page, index: index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Bottom area: indicator + buttons
            VStack(spacing: Spacing.lg) {
                // Page indicator
                pageIndicator

                // Navigation
                navigationArea
            }
            .padding(.bottom, Spacing.lg)
        }
        .background(theme.background)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.2)) {
                appeared = true
            }
        }
    }

    // MARK: - Page Content

    private func pageContent(_ page: OnboardingPage, index: Int) -> some View {
        VStack(spacing: Spacing.lg) {
            Spacer(minLength: Spacing.lg)

            // Icon with animated background
            ZStack {
                // Outer glow
                Circle()
                    .fill(page.iconColor.opacity(0.08))
                    .frame(width: 160, height: 160)
                    .scaleEffect(appeared ? 1.0 : 0.6)

                // Middle ring
                Circle()
                    .fill(page.iconColor.opacity(0.12))
                    .frame(width: 110, height: 110)
                    .scaleEffect(appeared ? 1.0 : 0.7)

                // Icon container
                Image(systemName: page.icon)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(page.iconColor)
                    .frame(width: 80, height: 80)
                    .background(
                        Circle()
                            .fill(page.iconColor.opacity(0.15))
                    )
                    .scaleEffect(appeared ? 1.0 : 0.5)
            }
            .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.1), value: appeared)

            // Text content
            VStack(spacing: Spacing.sm) {
                Text(page.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(page.subtitle)
                    .font(AppTypography.bodyLargeFont)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Spacing.lg)

            // Features list
            VStack(spacing: Spacing.md) {
                ForEach(Array(page.features.enumerated()), id: \.offset) { featureIndex, feature in
                    featureRow(feature, index: featureIndex)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.sm)

            Spacer(minLength: Spacing.xl)
        }
    }

    // MARK: - Feature Row

    private func featureRow(_ feature: OnboardingFeature, index: Int) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: feature.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.brandPrimary)
                .frame(width: 36, height: 36)
                .background(theme.brandPrimary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))

            Text(feature.text)
                .font(AppTypography.bodyMediumFont)
                .foregroundStyle(theme.textSecondary)

            Spacer()
        }
    }

    // MARK: - Page Indicator

    private var pageIndicator: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(0..<pages.count, id: \.self) { index in
                Capsule()
                    .fill(
                        index == currentPage
                        ? theme.brandPrimary
                        : theme.divider
                    )
                    .frame(
                        width: index == currentPage ? 24 : 8,
                        height: 8
                    )
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentPage)
            }
        }
    }

    // MARK: - Navigation Area

    private var navigationArea: some View {
        HStack {
            // Skip button
            Button {
                dismiss()
                onComplete()
            } label: {
                Text("Skip")
                    .font(AppTypography.labelMediumFont)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
            }

            Spacer()

            // Next / Get Started button
            Button {
                if currentPage < pages.count - 1 {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        currentPage += 1
                    }
                } else {
                    dismiss()
                    onComplete()
                }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Text(currentPage == pages.count - 1 ? "Get Started" : "Next")
                        .font(AppTypography.labelLargeFont)

                    Image(systemName: currentPage == pages.count - 1 ? "arrow.right" : "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                }
                .foregroundStyle(theme.buttonPrimaryText)
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)
            }
            .background(
                Capsule()
                    .fill(theme.buttonPrimary)
                    .shadow(color: theme.buttonPrimary.opacity(0.3), radius: 8, y: 4)
            )
            .clipShape(Capsule())
            .pressEffect()
        }
        .padding(.horizontal, Spacing.screenPadding)
    }
}

// MARK: - Onboarding Page Model

private struct OnboardingPage {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let features: [OnboardingFeature]
}

private struct OnboardingFeature {
    let icon: String
    let text: String
}
