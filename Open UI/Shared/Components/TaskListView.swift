import SwiftUI

// MARK: - Task List Panel

/// Collapsible task list panel shown above the chat input field when a
/// conversation has active tasks (created via the model's `create_tasks` /
/// `update_task` built-in tools). Matches the web UI's bottom task panel.
struct TaskListView: View {
    let tasks: [ChatTask]
    /// Whether a streaming request is currently in flight. The spinner in the
    /// header is only shown when this is true AND tasks are in progress — so
    /// reopening a chat with existing in_progress tasks doesn't show a spurious
    /// spinner when nothing is actually happening.
    var isStreaming: Bool = false

    @State private var isExpanded: Bool = false
    @Environment(\.theme) private var theme

    private var completedCount: Int { tasks.filter(\.isCompleted).count }
    private var totalCount: Int { tasks.count }
    private var allDone: Bool { tasks.allSatisfy { $0.isCompleted || $0.isCancelled } }
    /// Only true when there is an active request AND tasks have in_progress status.
    private var hasActiveWork: Bool { isStreaming && tasks.contains(where: \.isInProgress) }

    var body: some View {
        if tasks.isEmpty { return AnyView(EmptyView()) }

        return AnyView(
            VStack(spacing: 0) {
                // ── Header ─────────────────────────────────────────────────
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        // Animated status icon
                        if hasActiveWork {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(theme.brandPrimary)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: allDone ? "checkmark.circle.fill" : "checklist")
                                .scaledFont(size: 13)
                                .foregroundStyle(allDone ? theme.success : theme.textTertiary)
                        }

                        // Progress summary
                        Text(headerText)
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(theme.textSecondary)

                        Spacer()

                        // Progress bar
                        progressBar
                            .frame(width: 60, height: 4)

                        // Expand chevron
                        ExpandChevron(isExpanded: isExpanded)
                            .foregroundStyle(theme.textTertiary)
                    }
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // ── Expanded task list ──────────────────────────────────────
                if isExpanded {
                    Divider()
                        .overlay(theme.cardBorder.opacity(0.3))

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(tasks) { task in
                                TaskRowView(task: task)

                                if task.id != tasks.last?.id {
                                    Divider()
                                        .padding(.leading, 44)
                                        .overlay(theme.cardBorder.opacity(0.2))
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .background(theme.surfaceContainer.opacity(theme.isDark ? 0.7 : 0.5))
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(theme.cardBorder.opacity(0.4)),
                alignment: .top
            )
            .animation(.easeInOut(duration: 0.22), value: isExpanded)
            .animation(.easeInOut(duration: 0.3), value: completedCount)
        )
    }

    // MARK: - Header text

    private var headerText: String {
        if allDone {
            return "\(completedCount) of \(totalCount) tasks completed"
        } else {
            return "\(completedCount) of \(totalCount) tasks completed"
        }
    }

    // MARK: - Progress bar

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.cardBorder.opacity(0.4))

                RoundedRectangle(cornerRadius: 2)
                    .fill(allDone ? theme.success : theme.brandPrimary)
                    .frame(width: totalCount > 0 ? geo.size.width * CGFloat(completedCount) / CGFloat(totalCount) : 0)
                    .animation(.easeOut(duration: 0.3), value: completedCount)
            }
        }
    }
}

// MARK: - Task Row

/// Read-only task row. Task status is controlled by the server
/// (native `chat:message:tasks` snapshots), matching the web UI.
private struct TaskRowView: View {
    let task: ChatTask

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            statusIcon
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)

            // Task content
            Text(task.content)
                .scaledFont(size: 13)
                .foregroundStyle(task.isCancelled || task.isCompleted ? theme.textTertiary : theme.textPrimary)
                .strikethrough(task.isCompleted || task.isCancelled, color: theme.textTertiary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)

            Spacer(minLength: 0)

            // Status badge (only for in_progress and cancelled)
            if task.isInProgress || task.isCancelled {
                statusBadge
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(task.content)
        .accessibilityValue(task.status.replacingOccurrences(of: "_", with: " "))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 16)
                .foregroundStyle(Color.green.opacity(0.8))

        case "in_progress":
            ZStack {
                Circle()
                    .stroke(theme.brandPrimary.opacity(0.3), lineWidth: 1.5)
                ProgressView()
                    .controlSize(.mini)
                    .tint(theme.brandPrimary)
                    .scaleEffect(0.7)
            }

        case "cancelled":
            Image(systemName: "xmark.circle")
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)

        default: // pending
            Circle()
                .stroke(theme.cardBorder.opacity(0.8), lineWidth: 1.5)
                .frame(width: 16, height: 16)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if task.isInProgress {
            Text("In Progress")
                .scaledFont(size: 10, weight: .medium)
                .foregroundStyle(theme.brandPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(theme.brandPrimary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else if task.isCancelled {
            Text("Cancelled")
                .scaledFont(size: 10, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(theme.textTertiary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}

// MARK: - Collection safe subscript helper

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
