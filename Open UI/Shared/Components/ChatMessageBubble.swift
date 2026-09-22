import SwiftUI

// MARK: - Chat Message Bubble

/// A chat message bubble that adapts its appearance based on the
/// sender role (user vs assistant).
///
/// ## Design
/// - **User messages**: Right-aligned rounded rectangle with brand accent
///   color and uniform corners.
/// - **Assistant messages**: Full-width, no background — clean like
///   Claude.ai and ChatGPT native. Only a subtle label/avatar above.
/// - **System messages**: Center-aligned muted label.
struct ChatMessageBubble<Content: View>: View {
    let role: MessageRole
    let showTimestamp: Bool
    let timestamp: Date?
    @ViewBuilder let content: () -> Content

    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        role: MessageRole,
        showTimestamp: Bool = false,
        timestamp: Date? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.role = role
        self.showTimestamp = showTimestamp
        self.timestamp = timestamp
        self.content = content
    }

    var body: some View {
        Group {
            switch role {
            case .user:
                userBubble
            case .assistant:
                assistantContent
            case .system:
                systemContent
            }
        }
    }

    // MARK: - User Bubble

    private var userBubble: some View {
        // Cap the bubble at 80% of the physical screen width so it never
        // overflows on small devices (iPhone SE) or wide columns (iPad).
        // Using UIScreen.main.bounds.width is intentional — we want the
        // physical screen width as the cap, not the SwiftUI container width,
        // and avoiding GeometryReader prevents the zero-height collapse bug
        // that occurs when GeometryReader is inside a ScrollView.
        let maxBubbleWidth = UIScreen.main.bounds.width * 0.80

        return HStack(alignment: .bottom, spacing: 0) {
            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                content()
                    .foregroundStyle(theme.chatBubbleUserText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(theme.chatBubbleUser)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                // AnimatedPresence smoothly expands the ~18pt height when the
                // timestamp toggles (user tap) instead of snapping.
                AnimatedPresence(visible: showTimestamp && timestamp != nil) {
                    if showTimestamp, let ts = timestamp {
                        Text(ts, style: .time)
                            .scaledFont(size: 11)
                            .foregroundStyle(theme.textTertiary)
                            .padding(.trailing, 4)
                    }
                }
            }
            .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 2)
    }

    // MARK: - Assistant Content (no bubble — clean full-width)

    private var assistantContent: some View {
        // Cap assistant content so that content frame + horizontal padding = screen width.
        // Subtracting the padding from the cap here prevents the total rendered width
        // from exceeding UIScreen width — which was causing a horizontal overflow on
        // smaller devices (iPhone 12 Pro etc.) that stretched the entire chat layout
        // including the navbar and input bar beyond the visible viewport.
        let maxContentWidth = UIScreen.main.bounds.width - (Spacing.screenPadding * 2)

        return VStack(alignment: .leading, spacing: 4) {
            content()
                .foregroundStyle(theme.chatBubbleAssistantText)
                .frame(maxWidth: .infinity, alignment: .leading)
            AnimatedPresence(visible: showTimestamp && timestamp != nil) {
                if showTimestamp, let ts = timestamp {
                    Text(ts, style: .time)
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .frame(maxWidth: maxContentWidth, alignment: .leading)
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 2)
    }

    // MARK: - System Content

    private var systemContent: some View {
        HStack {
            Spacer()
            content()
                .foregroundStyle(theme.textTertiary)
                .scaledFont(size: 12)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(theme.surfaceContainer.opacity(0.6))
                .clipShape(Capsule())
            Spacer()
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: - Blinking Cursor Indicator

/// A minimal blinking cursor shown while the assistant is waiting to respond.
/// Replaces the old bouncing-dots TypingIndicator with a clean, non-bouncing
/// vertical bar that fades in and out — like a text cursor about to type.
struct BlinkingCursorIndicator: View {
    @State private var opacity: Double = 0.2
    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(theme.textSecondary)
            .frame(width: 2, height: 16)
            .opacity(opacity)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.9)
                        .repeatForever(autoreverses: true)
                ) {
                    opacity = 0.9
                }
            }
            .onDisappear {
                withAnimation(nil) { opacity = 0.2 }
            }
    }
}

// MARK: - Message Action Bar

/// A horizontal bar of action buttons shown beneath a message bubble.
struct MessageActionBar: View {
    let onCopy: () -> Void
    var onRegenerate: (() -> Void)?
    var onEdit: (() -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Spacing.xs) {
            actionButton(systemImage: "doc.on.doc", accessibilityLabel: "Copy", action: onCopy)
            if let onRegenerate {
                actionButton(systemImage: "arrow.clockwise", accessibilityLabel: "Regenerate", action: onRegenerate)
            }
            if let onEdit {
                actionButton(systemImage: "pencil", accessibilityLabel: "Edit", action: onEdit)
            }
        }
    }

    private func actionButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Previews

#Preview("Chat Bubbles") {
    ScrollView {
        VStack(spacing: 0) {
            // Assistant message (no bubble)
            ChatMessageBubble(role: .assistant) {
                Text("Hello! How can I help you today? I'm ready to assist with anything you need.")
            }

            // User message (uniform rounded corners)
            ChatMessageBubble(role: .user) {
                Text("Tell me about SwiftUI theming")
            }

            // Assistant message with longer text
            ChatMessageBubble(role: .assistant) {
                Text("SwiftUI provides a powerful theming system through Environment values and custom ViewModifiers. You can create a design token system and inject it via `.environment`.")
            }

            // User message with timestamp
            ChatMessageBubble(role: .user, showTimestamp: true, timestamp: .now) {
                Text("That's really helpful!")
            }

            // Blinking cursor indicator
            HStack {
                VStack(alignment: .leading) {
                    BlinkingCursorIndicator()
                }
                .padding(.horizontal, Spacing.screenPadding)
                Spacer()
            }

            // Skeleton messages
            SkeletonChatMessage(isUser: false, lineCount: 3)
            SkeletonChatMessage(isUser: true, lineCount: 2)
        }
        .padding(.vertical)
    }
    .themed()
}
