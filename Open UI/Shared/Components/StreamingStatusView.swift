import SwiftUI

// MARK: - Streaming Status View

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

                // Search queries section (shown for the latest status if it has queries)
                if let latest = latestStatus, !latest.queries.isEmpty {
                    queriesSection(latest)
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
                VStack(alignment: .leading, spacing: 2) {
                    if let latest = latestStatus {
                        let title = resolveStatusDescription(for: latest)
                        if latest.done == true {
                            Text(title)
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        } else {
                            ShimmerText(text: title, theme: theme)
                        }

                        // Show count if available (e.g., "Retrieved 17 sources")
                        if let count = latest.count, count > 0, latest.done == true {
                            Text("Retrieved \(count) source\(count == 1 ? "" : "s")")
                                .scaledFont(size: 11, weight: .regular)
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                if visibleStatuses.count > 1 {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 10, weight: .semibold)
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
                let title = resolveStatusDescription(for: status)
                if status.done == true {
                    Text(title)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .strikethrough(true)
                } else {
                    ShimmerText(text: title, theme: theme)
                }

                // Show URLs if present
                if !status.urls.isEmpty {
                    ForEach(status.urls, id: \.self) { url in
                        Text(url)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.brandPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    // MARK: - Queries Section

    @ViewBuilder
    private func queriesSection(_ status: ChatStatusUpdate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(status.queries.enumerated()), id: \.offset) { _, query in
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                    Text(query)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.surfaceContainer.opacity(theme.isDark ? 0.5 : 0.8))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
                )
            }
        }
        .padding(.leading, Spacing.lg)
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private func statusIndicator(for status: ChatStatusUpdate?) -> some View {
        if let status, status.done == true {
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 14)
                .foregroundStyle(theme.success)
                .transition(.scale.combined(with: .opacity))
        } else {
            PulsingDot(color: theme.brandPrimary)
        }
    }

    // MARK: - Status Resolution

    private func resolveStatusDescription(for status: ChatStatusUpdate) -> String {
        let action = status.action ?? ""
        let desc = status.description
        let isDone = status.done == true

        switch action.lowercased() {
        case "web_search", "websearch", "web search":
            if isDone {
                if let count = status.count, count > 0 {
                    return "Searched \(count) site\(count == 1 ? "" : "s")"
                }
                return desc ?? "Searched the web"
            }
            if let query = status.query, !query.isEmpty {
                return "Searching for '\(query)'"
            }
            if !status.queries.isEmpty {
                return "Searching"
            }
            return desc ?? "Searching the web"

        case "generate_image", "image_generation", "generateimage":
            if isDone { return desc ?? "Image generated" }
            return desc ?? "Generating image…"

        case "code_interpreter", "codeinterpreter", "code interpreter":
            if isDone { return desc ?? "Code executed" }
            return desc ?? "Running code…"

        case "tool_call", "execute_tool":
            return desc ?? (isDone ? "Tool completed" : "Executing tool…")

        case "memory", "memory_search":
            if isDone { return desc ?? "Memory retrieved" }
            return desc ?? "Searching memory…"

        case "knowledge", "knowledge_search", "rag":
            if isDone {
                if let count = status.count, count > 0 {
                    return "Retrieved \(count) source\(count == 1 ? "" : "s")"
                }
                return desc ?? "Knowledge retrieved"
            }
            return desc ?? "Querying knowledge base…"

        case "reconnecting":
            return desc ?? "Reconnecting…"

        default:
            // Fall back to server description or formatted action name
            if let desc, !desc.isEmpty { return desc }
            if !action.isEmpty { return formatActionName(action) }
            return "Processing…"
        }
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

// MARK: - Pulsing Dot

struct PulsingDot: View {
    let color: Color
    @State private var opacity: Double = 0.3

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(opacity)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.8)
                    .repeatForever(autoreverses: true)
                ) {
                    opacity = 1.0
                }
            }
    }
}

// MARK: - Shimmer Text

private struct ShimmerText: View {
    let text: String
    let theme: AppTheme
    @State private var shimmerPhase: CGFloat = -1.0

    var body: some View {
        Text(text)
            .scaledFont(size: 12, weight: .medium)
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [
                            .clear,
                            theme.brandPrimary.opacity(0.35),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.4)
                    .offset(x: shimmerPhase * geo.size.width)
                    .blendMode(.sourceAtop)
                }
                .mask {
                    Text(text)
                        .scaledFont(size: 12, weight: .medium)
                        .lineLimit(1)
                }
            }
            .onAppear {
                withAnimation(
                    .linear(duration: 1.8)
                    .repeatForever(autoreverses: false)
                ) {
                    shimmerPhase = 1.2
                }
            }
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
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.success)
            } else {
                PulsingDot(color: theme.brandPrimary)
            }

            Text(action)
                .scaledFont(size: 12, weight: .medium)
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
