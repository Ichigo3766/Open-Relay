import SwiftUI

// MARK: - Skeleton Loader

/// A shimmer-animated placeholder view for loading content.
///
/// Usage:
/// ```swift
/// SkeletonLoader(width: 200, height: 16)
/// SkeletonLoader(height: 48, cornerRadius: .input)
/// ```
struct SkeletonLoader: View {
    var width: CGFloat? = nil
    var height: CGFloat = 16
    var cornerRadius: CGFloat = CornerRadius.sm

    @Environment(\.theme) private var theme
    @State private var phase: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(theme.shimmerBase)
            .frame(width: width, height: height)
            .overlay(shimmerGradient)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onAppear { startAnimation() }
    }

    private var shimmerGradient: some View {
        GeometryReader { geo in
            let w = geo.size.width
            LinearGradient(
                colors: [.clear, theme.shimmerHighlight.opacity(0.6), .clear],
                startPoint: .init(x: phase - 0.3, y: 0.5),
                endPoint: .init(x: phase + 0.3, y: 0.5)
            )
            .frame(width: w)
        }
    }

    private func startAnimation() {
        withAnimation(
            .linear(duration: 1.5)
            .repeatForever(autoreverses: false)
        ) {
            phase = 1.5
        }
    }
}

// MARK: - Skeleton Chat Message

/// Placeholder skeleton for a chat message row.
struct SkeletonChatMessage: View {
    var isUser: Bool = false
    var lineCount: Int = 2

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            if !isUser {
                SkeletonLoader(width: 36, height: 36, cornerRadius: 6)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: Spacing.xs) {
                ForEach(0..<lineCount, id: \.self) { index in
                    SkeletonLoader(
                        width: index == lineCount - 1 ? 120 : nil,
                        height: 14
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            if isUser {
                SkeletonLoader(width: 36, height: 36, cornerRadius: 18)
            }
        }
        .padding(.horizontal, Spacing.messagePadding)
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: - Skeleton List Item

/// Placeholder skeleton for a list item.
struct SkeletonListItem: View {
    var showAvatar: Bool = true
    var showSubtitle: Bool = true

    var body: some View {
        HStack(spacing: Spacing.md) {
            if showAvatar {
                SkeletonLoader(width: 40, height: 40, cornerRadius: 20)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                SkeletonLoader(height: 16)
                if showSubtitle {
                    SkeletonLoader(width: 180, height: 14)
                }
            }
        }
        .padding(Spacing.md)
    }
}

// MARK: - Skeleton Card

/// Placeholder skeleton for a card layout.
struct SkeletonCard: View {
    var showTitle: Bool = true
    var showActions: Bool = false

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if showTitle {
                SkeletonLoader(width: 200, height: 20)
            }

            SkeletonLoader(height: 14)
            SkeletonLoader(width: 160, height: 14)

            if showActions {
                HStack {
                    Spacer()
                    SkeletonLoader(width: 80, height: 36, cornerRadius: CornerRadius.button)
                    SkeletonLoader(width: 80, height: 36, cornerRadius: CornerRadius.button)
                }
            }
        }
        .padding(Spacing.cardPadding)
        .cardStyle()
    }
}

// MARK: - Loading Indicator

/// A themed loading spinner with an optional message.
struct LoadingIndicator: View {
    var message: String?
    var size: CGFloat = IconSize.lg

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Spacing.sm) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(theme.brandPrimary)
                .scaleEffect(size / 20)

            if let message {
                Text(LocalizedStringKey(message))
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }
}

// MARK: - Loading Overlay

/// A full-screen loading overlay with a centered spinner and message.
struct LoadingOverlay: View {
    var message: String?

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.background.opacity(OpacityLevel.strong)
                .ignoresSafeArea()

            VStack(spacing: Spacing.md) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(theme.brandPrimary)
                    .scaleEffect(1.5)

                if let message {
                    Text(LocalizedStringKey(message))
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(Spacing.xl)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
            .shadowLg()
        }
        .transition(.opacity.animation(.easeOut(duration: AnimDuration.fast)))
    }
}

// MARK: - Loading Button

/// A button that shows a loading spinner when performing an async action.
struct LoadingButton: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void

    var isPrimary: Bool = true

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(isPrimary ? theme.buttonPrimaryText : theme.textPrimary)
                        .scaleEffect(0.8)
                }
                Text(title)
                    .scaledFont(size: 16, weight: .medium)
            }
            .frame(maxWidth: .infinity)
            .frame(height: TouchTarget.comfortable)
        }
        .buttonStyle(.borderedProminent)
        .tint(isPrimary ? theme.buttonPrimary : theme.buttonSecondary)
        .foregroundStyle(isPrimary ? theme.buttonPrimaryText : theme.buttonSecondaryText)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous))
        .disabled(isLoading)
    }
}

// MARK: - Previews

#Preview("Skeleton Loaders") {
    ScrollView {
        VStack(spacing: Spacing.lg) {
            Group {
                Text("Chat Messages").font(.headline)
                SkeletonChatMessage()
                SkeletonChatMessage(isUser: true, lineCount: 1)
                SkeletonChatMessage(lineCount: 3)
            }

            Divider()

            Group {
                Text("List Items").font(.headline)
                SkeletonListItem()
                SkeletonListItem(showSubtitle: false)
            }

            Divider()

            Group {
                Text("Cards").font(.headline)
                SkeletonCard()
                SkeletonCard(showActions: true)
            }

            Divider()

            Group {
                Text("Loading").font(.headline)
                LoadingIndicator(message: "Loading content…")
                LoadingButton(title: "Save", isLoading: true, action: {})
                LoadingButton(title: "Cancel", isLoading: false, action: {}, isPrimary: false)
            }
        }
        .padding()
    }
    .themed()
}
