import SwiftUI

// MARK: - Onboarding View

/// Full-screen onboarding experience for first-time users.
/// Clean, spacious, modern design — no gradients, just solid tints and bold typography.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var currentPage = 0
    @State private var pageAppeared: [Bool] = Array(repeating: false, count: 4)

    let userName: String
    let onComplete: () -> Void

    private let totalPages = 4

    var body: some View {
        ZStack {
            // Background
            theme.background
                .ignoresSafeArea()

            // Decorative floating shapes
            floatingDecor
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Skip button row
                HStack {
                    Spacer()
                    if currentPage < totalPages - 1 {
                        Button {
                            dismiss()
                            onComplete()
                        } label: {
                            Text("Skip")
                                .scaledFont(size: 16, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                                .padding(.horizontal, Spacing.md)
                                .padding(.vertical, Spacing.sm)
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.top, Spacing.sm)
                .frame(height: 44)

                // Page content
                TabView(selection: $currentPage) {
                    welcomePage.tag(0)
                    chatPage.tag(1)
                    voicePage.tag(2)
                    getStartedPage.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .onChange(of: currentPage) { _, newPage in
                    triggerPageAppear(newPage)
                }

                // Bottom area
                VStack(spacing: Spacing.lg) {
                    pageIndicator
                    continueButton
                }
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.bottom, Spacing.xl)
            }
        }
        .onAppear {
            triggerPageAppear(0)
        }
    }

    // MARK: - Page Indicator

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalPages, id: \.self) { index in
                Capsule()
                    .fill(index == currentPage ? theme.brandPrimary : theme.divider)
                    .frame(width: index == currentPage ? 28 : 8, height: 6)
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: currentPage)
            }
        }
    }

    // MARK: - Continue Button

    private var continueButton: some View {
        Button {
            Haptics.play(.light)
            if currentPage < totalPages - 1 {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    currentPage += 1
                }
            } else {
                dismiss()
                onComplete()
            }
        } label: {
            Text(currentPage == totalPages - 1 ? "Get started" : "Continue")
                .scaledFont(size: 17, weight: .semibold)
                .foregroundStyle(theme.buttonPrimaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(theme.buttonPrimary)
                )
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .pressEffect()
    }

    // MARK: - Floating Decor

    private var floatingDecor: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            // Top-right circle
            Circle()
                .fill(theme.brandPrimary.opacity(theme.isDark ? 0.04 : 0.05))
                .frame(width: 260, height: 260)
                .offset(x: w * 0.35, y: -60)

            // Bottom-left circle
            Circle()
                .fill(theme.brandPrimary.opacity(theme.isDark ? 0.03 : 0.04))
                .frame(width: 200, height: 200)
                .offset(x: -80, y: h * 0.65)
        }
    }

    // MARK: - Trigger Page Appear

    private func triggerPageAppear(_ page: Int) {
        // Reset so re-visiting replays the stagger
        pageAppeared[page] = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
                pageAppeared[page] = true
            }
        }
    }

    // MARK: - Helper: Stagger Offset & Opacity

    private func stagger(_ page: Int, index: Int) -> (Double, CGFloat) {
        let visible = pageAppeared[page]
        let opacity: Double = visible ? 1 : 0
        let offset: CGFloat = visible ? 0 : 20
        return (opacity, offset)
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        let (o0, y0) = stagger(0, index: 0)
        let (o1, y1) = stagger(0, index: 1)
        let (o2, y2) = stagger(0, index: 2)

        return VStack(spacing: 0) {
            Spacer()

            // App icon area
            Image("AppIconImage")
                .resizable()
                .scaledToFill()
                .frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .opacity(o0)
            .offset(y: y0)
            .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.0), value: pageAppeared[0])

            Spacer().frame(height: Spacing.xl)

            // Title
            VStack(spacing: Spacing.sm) {
                Text("Welcome, \(userName)!")
                    .scaledFont(size: 34, weight: .bold, design: .rounded)
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .opacity(o1)
            .offset(y: y1)
            .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.08), value: pageAppeared[0])

            Spacer().frame(height: Spacing.md)

            // Subtitle
            Text("Your AI conversations,\nbeautifully native.")
                .scaledFont(size: 18, weight: .regular)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .opacity(o2)
                .offset(y: y2)
                .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.16), value: pageAppeared[0])

            Spacer()
            Spacer()
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    // MARK: - Page 2: Chat

    private var chatPage: some View {
        let (o0, y0) = stagger(1, index: 0)
        let (o1, y1) = stagger(1, index: 1)
        let (o2, y2) = stagger(1, index: 2)
        let (o3, y3) = stagger(1, index: 3)

        return VStack(spacing: 0) {
            Spacer()

            // Hero icon
            heroIcon(
                symbol: "bubble.left.and.bubble.right.fill",
                tint: .blue,
                page: 1,
                delay: 0.0
            )
            .opacity(o0)
            .offset(y: y0)
            .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.0), value: pageAppeared[1])

            Spacer().frame(height: Spacing.xl)

            // Title
            Text("Chat with AI")
                .scaledFont(size: 34, weight: .bold, design: .rounded)
                .foregroundStyle(theme.textPrimary)
                .opacity(o1)
                .offset(y: y1)
                .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.08), value: pageAppeared[1])

            Spacer().frame(height: Spacing.sm)

            Text("Multiple models. One beautiful app.")
                .scaledFont(size: 18, weight: .regular)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .opacity(o2)
                .offset(y: y2)
                .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.14), value: pageAppeared[1])

            Spacer().frame(height: Spacing.xl)

            // Feature chips
            featureChips(
                items: [
                    ("cpu", "Multiple Models"),
                    ("bolt.fill", "Fast & Native"),
                    ("doc.fill", "Attach Files")
                ]
            )
            .opacity(o3)
            .offset(y: y3)
            .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.22), value: pageAppeared[1])

            Spacer()
            Spacer()
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    // MARK: - Page 3: Voice

    private var voicePage: some View {
        let (o0, y0) = stagger(2, index: 0)
        let (o1, y1) = stagger(2, index: 1)
        let (o2, y2) = stagger(2, index: 2)
        let (o3, y3) = stagger(2, index: 3)

        return VStack(spacing: 0) {
            Spacer()

            // Hero icon
            heroIcon(
                symbol: "waveform.circle.fill",
                tint: .green,
                page: 2,
                delay: 0.0
            )
            .opacity(o0)
            .offset(y: y0)
            .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.0), value: pageAppeared[2])

            Spacer().frame(height: Spacing.xl)

            Text("Voice & Audio")
                .scaledFont(size: 34, weight: .bold, design: .rounded)
                .foregroundStyle(theme.textPrimary)
                .opacity(o1)
                .offset(y: y1)
                .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.08), value: pageAppeared[2])

            Spacer().frame(height: Spacing.sm)

            Text("Speak naturally. Listen back.")
                .scaledFont(size: 18, weight: .regular)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .opacity(o2)
                .offset(y: y2)
                .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.14), value: pageAppeared[2])

            Spacer().frame(height: Spacing.xl)

            // Feature chips
            featureChips(
                items: [
                    ("mic.fill", "Voice Input"),
                    ("speaker.wave.2.fill", "Text-to-Speech"),
                    ("phone.fill", "Voice Calls")
                ]
            )
            .opacity(o3)
            .offset(y: y3)
            .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.22), value: pageAppeared[2])

            Spacer()
            Spacer()
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    // MARK: - Page 4: Get Started

    private var getStartedPage: some View {
        let (o0, y0) = stagger(3, index: 0)
        let (o1, y1) = stagger(3, index: 1)
        let (o2, y2) = stagger(3, index: 2)
        let (o3, y3) = stagger(3, index: 3)

        return VStack(spacing: 0) {
            Spacer()

            // Hero icon
            heroIcon(
                symbol: "rocket.fill",
                tint: .orange,
                page: 3,
                delay: 0.0
            )
            .opacity(o0)
            .offset(y: y0)
            .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.0), value: pageAppeared[3])

            Spacer().frame(height: Spacing.xl)

            Text("You're All Set")
                .scaledFont(size: 34, weight: .bold, design: .rounded)
                .foregroundStyle(theme.textPrimary)
                .opacity(o1)
                .offset(y: y1)
                .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.08), value: pageAppeared[3])

            Spacer().frame(height: Spacing.sm)

            Text("Here are a few tips to get you going.")
                .scaledFont(size: 18, weight: .regular)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .opacity(o2)
                .offset(y: y2)
                .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.14), value: pageAppeared[3])

            Spacer().frame(height: Spacing.xl)

            // Tips
            VStack(spacing: Spacing.md) {
                tipRow(icon: "hand.draw.fill", text: "Swipe right to see chat history")
                tipRow(icon: "plus.circle.fill", text: "Tap + to start a new conversation")
                tipRow(icon: "gearshape.fill", text: "Customize everything in Settings")
            }
            .opacity(o3)
            .offset(y: y3)
            .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.22), value: pageAppeared[3])

            Spacer()
            Spacer()
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    // MARK: - Reusable Components

    /// Large hero icon with a soft tinted background
    private func heroIcon(symbol: String, tint: Color, page: Int, delay: Double) -> some View {
        ZStack {
            Circle()
                .fill(tint.opacity(theme.isDark ? 0.10 : 0.07))
                .frame(width: 140, height: 140)

            Image(systemName: symbol)
                .scaledFont(size: 56, weight: .medium)
                .foregroundStyle(tint)
        }
    }

    /// Horizontal row of compact pill-shaped feature chips
    private func featureChips(items: [(icon: String, label: String)]) -> some View {
        HStack(spacing: Spacing.sm) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    Image(systemName: item.icon)
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)

                    Text(item.label)
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.surfaceContainer)
                )
            }
        }
    }

    /// Minimal tip row with icon and text
    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .scaledFont(size: 18, weight: .medium)
                .foregroundStyle(theme.brandPrimary)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.brandPrimary.opacity(theme.isDark ? 0.12 : 0.08))
                )

            Text(text)
                .scaledFont(size: 16, weight: .regular)
                .foregroundStyle(theme.textSecondary)

            Spacer()
        }
        .padding(.horizontal, Spacing.md)
    }
}
