import SwiftUI

// MARK: - Streaming Status View

/// Displays status updates during assistant response streaming, such as
/// tool calls, web searches, and other intermediate actions.
///
/// Mirrors the Flutter ``StreamingStatusWidget`` behavior, showing a
/// collapsible list of status events with animated indicators.
///
/// Usage:
/// ```swift
/// StreamingStatusView(statusHistory: message.statusHistory)
/// ```
struct StreamingStatusView: View {
    let statusHistory: [ChatStatusUpdate]
    var isStreaming: Bool = true

    @Environment(\.theme) private var theme
    @State private var isExpanded = true

    /// Visible (non-hidden) status items.
    private var visibleStatuses: [ChatStatusUpdate] {
        statusHistory.filter { $0.hidden != true }
    }

    /// The most recent status update.
    private var latestStatus: ChatStatusUpdate? {
        visibleStatuses.last
    }

    /// Whether all status updates are marked done.
    private var allDone: Bool {
        visibleStatuses.allSatisfy { $0.done == true }
    }

    var body: some View {
        if visibleStatuses.isEmpty { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: Spacing.xs) {
                // Header row with latest status
                statusHeader

                // Expanded list of all statuses
                if isExpanded && visibleStatuses.count > 1 {
                    statusList
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.vertical, Spacing.xs)
            .animation(MicroAnimation.snappy, value: isExpanded)
            .animation(MicroAnimation.gentle, value: visibleStatuses.count)
        )
    }

    // MARK: - Header

    private var statusHeader: some View {
        Button {
            withAnimation(MicroAnimation.snappy) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: Spacing.sm) {
                // Spinning indicator or checkmark
                statusIndicator(for: latestStatus)

                // Status text
                VStack(alignment: .leading, spacing: 0) {
                    if let latest = latestStatus {
                        Text(statusTitle(for: latest))
                            .font(AppTypography.labelSmallFont)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)

                        if let desc = latest.description, !desc.isEmpty {
                            Text(desc)
                                .font(AppTypography.captionFont)
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                if visibleStatuses.count > 1 {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status List

    private var statusList: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(Array(visibleStatuses.enumerated()), id: \.offset) { index, status in
                if index < visibleStatuses.count - 1 {
                    statusRow(status)
                }
            }
        }
        .padding(.leading, Spacing.lg)
    }

    private func statusRow(_ status: ChatStatusUpdate) -> some View {
        HStack(spacing: Spacing.sm) {
            statusIndicator(for: status)
                .scaleEffect(0.8)

            VStack(alignment: .leading, spacing: 0) {
                Text(statusTitle(for: status))
                    .font(AppTypography.captionFont)
                    .foregroundStyle(
                        status.done == true
                            ? theme.textTertiary
                            : theme.textSecondary
                    )
                    .lineLimit(1)
                    .strikethrough(status.done == true)

                // Show URLs if present
                if !status.urls.isEmpty {
                    ForEach(status.urls, id: \.self) { url in
                        Text(url)
                            .font(AppTypography.captionFont)
                            .foregroundStyle(theme.brandPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private func statusIndicator(for status: ChatStatusUpdate?) -> some View {
        if let status, status.done == true {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(theme.success)
                .transition(.scale.combined(with: .opacity))
        } else if isStreaming {
            ProgressView()
                .controlSize(.mini)
                .tint(theme.brandPrimary)
        } else {
            Image(systemName: "circle")
                .font(.system(size: 14))
                .foregroundStyle(theme.textTertiary)
        }
    }

    // MARK: - Helpers

    private func statusTitle(for status: ChatStatusUpdate) -> String {
        if let action = status.action, !action.isEmpty {
            return formatActionName(action)
        }
        if let desc = status.description, !desc.isEmpty {
            return desc
        }
        return "Processing…"
    }

    private func formatActionName(_ action: String) -> String {
        // Convert snake_case or camelCase to readable format
        let cleaned = action
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(
                of: "([a-z])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )

        // Capitalize first letter
        return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
    }
}

// MARK: - Tool Call Status Badge

/// A compact badge showing that a tool is being called during streaming.
///
/// Displayed inline within the message content to show real-time tool usage.
struct ToolCallBadge: View {
    let action: String
    let isDone: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if isDone {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.success)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(theme.brandPrimary)
            }

            Text(action)
                .font(AppTypography.captionFont)
                .fontWeight(.medium)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(
            theme.surfaceContainer.opacity(theme.isDark ? 0.5 : 0.8)
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.5)
        )
    }
}

// MARK: - Preview

#Preview("Streaming Status") {
    VStack(spacing: Spacing.md) {
        StreamingStatusView(
            statusHistory: [
                ChatStatusUpdate(
                    action: "web_search",
                    description: "Searching for 'SwiftUI tools menu'",
                    done: true,
                    urls: ["https://developer.apple.com"]
                ),
                ChatStatusUpdate(
                    action: "code_interpreter",
                    description: "Running code snippet",
                    done: false
                ),
            ],
            isStreaming: true
        )

        Divider()

        ToolCallBadge(action: "Web Search", isDone: false)
        ToolCallBadge(action: "Code Interpreter", isDone: true)
    }
    .padding()
    .themed()
}
