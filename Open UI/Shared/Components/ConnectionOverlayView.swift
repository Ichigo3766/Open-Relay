import SwiftUI

/// Connection status indicator.
///
/// **With cached content** (`monitor.hasCachedContent == true`):
/// Shows a compact, dismissible top banner — the user can still browse their
/// saved chats and read previously opened conversations while offline.
///
/// **Without cached content** (`monitor.hasCachedContent == false`):
/// Shows the original full-screen blocking overlay so the user knows they
/// need a connection before any content is available.
///
/// Both variants automatically dismiss when the connection is restored.
struct ConnectionOverlayView: View {
    let monitor: ServerConnectionMonitor

    /// Called when the user taps "Switch Server".
    var onSwitchServer: (() -> Void)? = nil

    @Environment(\.theme) private var theme

    /// Whether the user has dismissed the offline banner (cached-content mode).
    @State private var bannerDismissed: Bool = false

    /// Elapsed time since disconnect, updated every second (blocking overlay only).
    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        if monitor.isShowingOverlay {
            if monitor.hasCachedContent {
                offlineBanner
            } else {
                blockingOverlay
            }
        }
    }

    // MARK: - Offline Banner (cached content available)

    /// Compact dismissible banner shown at the top of the screen when the app
    /// is offline but has cached conversations to browse.
    private var offlineBanner: some View {
        VStack {
            if !bannerDismissed {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: monitor.disconnectIcon)
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.warning)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(monitor.disconnectTitle)
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                        Text("Showing saved chats — read only")
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                    }

                    Spacer()

                    // Switch server button (if available)
                    if monitor.connectionState == .serverDown,
                       monitor.canSwitchServer,
                       let onSwitchServer {
                        Button(action: onSwitchServer) {
                            Text("Switch")
                                .scaledFont(size: 12, weight: .semibold)
                                .foregroundStyle(theme.brandPrimary)
                        }
                        .buttonStyle(.plain)
                    }

                    // Dismiss button
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            bannerDismissed = true
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(
                    theme.warning.opacity(0.12)
                        .background(theme.surfaceContainer)
                )
                .overlay(alignment: .bottom) {
                    Divider().opacity(0.4)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: bannerDismissed)
            }
            Spacer()
        }
        .onChange(of: monitor.isShowingOverlay) { _, showing in
            // Reset dismissed state when connection flips offline → online → offline
            if !showing { bannerDismissed = false }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Offline. \(monitor.disconnectTitle). Showing saved chats in read-only mode."))
    }

    // MARK: - Blocking Overlay (no cached content)

    /// Full-screen blocking overlay shown when offline and no cached content exists.
    private var blockingOverlay: some View {
        ZStack {
            // Semi-transparent background blocking interaction
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            // Centered card
            VStack(spacing: Spacing.lg) {
                // Animated icon
                iconView
                    .padding(.top, Spacing.sm)

                // Title
                Text(monitor.disconnectTitle)
                    .scaledFont(size: 20, weight: .semibold)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                // Message
                Text(monitor.disconnectMessage)
                    .scaledFont(size: 14)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)

                // Status row: spinner + attempt counter
                statusRow

                // Elapsed time
                if let since = monitor.disconnectedSince {
                    Text(formattedElapsed(since: since))
                        .scaledFont(size: 12)
                        .foregroundStyle(.white.opacity(0.5))
                }

                // "Switch Server" escape hatch — only when current server is down
                // (not internet down) and the user has other saved servers.
                if monitor.connectionState == .serverDown,
                   monitor.canSwitchServer,
                   let onSwitchServer {
                    Button(action: onSwitchServer) {
                        Label("Switch Server", systemImage: "arrow.left.arrow.right.circle")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, Spacing.lg)
                            .padding(.vertical, Spacing.sm)
                            .background(
                                Capsule()
                                    .fill(.white.opacity(0.18))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Switch to a different server"))
                }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 300)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        }
        .transition(.opacity.animation(.easeInOut(duration: AnimDuration.medium)))
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(monitor.disconnectTitle). \(monitor.disconnectMessage)"))
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - Icon

    private var iconView: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: 72, height: 72)

            Image(systemName: monitor.disconnectIcon)
                .scaledFont(size: 28, weight: .medium)
                .foregroundStyle(.white.opacity(0.9))
                .symbolEffect(.pulse, isActive: monitor.connectionState != .connected)
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView()
                .tint(.white)
                .controlSize(.small)

            if monitor.reconnectAttempt > 1 {
                Text("Attempt \(monitor.reconnectAttempt)")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(.white.opacity(0.65))
            } else {
                Text(monitor.connectionState == .internetDown
                     ? "Waiting for connection…"
                     : "Reconnecting…")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    // MARK: - Timer

    private func startTimer() {
        updateElapsed()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            updateElapsed()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateElapsed() {
        if let since = monitor.disconnectedSince {
            elapsedTime = Date().timeIntervalSince(since)
        }
    }

    private func formattedElapsed(since: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(since))
        if seconds < 60 {
            return "Disconnected \(seconds)s ago"
        } else {
            let minutes = seconds / 60
            return "Disconnected \(minutes)m ago"
        }
    }
}
