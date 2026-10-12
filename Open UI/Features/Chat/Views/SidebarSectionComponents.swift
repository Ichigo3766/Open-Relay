import SwiftUI

// MARK: - Sidebar Hierarchy (shared by MainChatView + iPadMainChatView)
//
// The sidebar uses three visual levels so it's obvious what belongs where:
//
//   Chats ⌄                              ← level 0: section header (bold, title case)
//       PINNED                           ← level 1: group label (small caps, indented)
//       │  Chat title                    ← level 2: nested row (indented + guide line)
//       │  Chat title
//       TODAY  3
//       │  Chat title
//
// Rows that sit directly under a section header (pinned models, folders)
// use the level-1 indent.
//
// Row content padding is `SidebarMetrics.rowInnerPadding`; apply
// `sidebarNestedRow()` at the call site *after* any `.frame(minHeight:)`
// so the guide line spans the full row height without gaps.

enum SidebarMetrics {
    /// Leading inset of top-level section headers.
    static let sectionInset: CGFloat = 16
    /// Leading position of level-1 content (group labels, direct child rows).
    static let childInset: CGFloat = 28
    /// X position of the vertical guide line drawn beside level-2 rows.
    static let guideX: CGFloat = 30
    /// Leading edge of a level-2 row's highlight pill.
    static let nestedRowLeading: CGFloat = 34
    /// Horizontal padding inside a row's highlight pill
    /// (matches `ChannelSidebarRowLabel`'s inner padding).
    static let rowInnerPadding: CGFloat = 10
    /// Trailing inset of row highlight pills from the sidebar edge.
    static let rowTrailing: CGFloat = 8
    /// Leading inset applied to folder rows so their chevron lines up
    /// with level-1 content (folder rows add 8pt before the chevron).
    static let folderRowLeading: CGFloat = childInset - Spacing.sm
}

// MARK: - Section Header (level 0)

/// Bold, collapsible header for a top-level sidebar section
/// (Models, Folders, Shared with Me, Channels, Chats).
struct SidebarSectionHeader<Trailing: View>: View {
    let title: String
    let isExpanded: Bool
    var tint: Color? = nil
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .scaledFont(size: 15, weight: .bold, context: .list)
                .foregroundStyle(tint ?? theme.textPrimary)
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .scaledFont(size: 10, weight: .bold, context: .list)
                .foregroundStyle(tint ?? theme.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
                .animation(MicroAnimation.snappy, value: isExpanded)

            Spacer(minLength: Spacing.sm)

            trailing()
        }
        .padding(.leading, SidebarMetrics.sectionInset)
        .padding(.trailing, Spacing.md)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

// MARK: - Group Label (level 1)

/// Small uppercase label that groups rows inside a section
/// (e.g. "Pinned", "Today", "Direct Messages"). Indented one level.
struct SidebarGroupLabel: View {
    let title: String
    var count: Int? = nil
    /// `nil` = not collapsible (no chevron shown).
    var isCollapsed: Bool? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .scaledFont(size: 11, weight: .semibold, context: .list)
                .foregroundStyle(theme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.6)
                .lineLimit(1)

            if let count {
                Text("\(count)")
                    .scaledFont(size: 10, weight: .medium, context: .list)
                    .foregroundStyle(theme.textTertiary)
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(theme.surfaceContainer)
                    .clipShape(Capsule())
            }

            if let isCollapsed {
                Image(systemName: "chevron.down")
                    .scaledFont(size: 8, weight: .bold, context: .list)
                    .foregroundStyle(theme.textTertiary.opacity(0.8))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .animation(.easeInOut(duration: AnimDuration.fast), value: isCollapsed)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, SidebarMetrics.childInset)
        .padding(.trailing, Spacing.md)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Guide Line

/// Faint vertical line drawn beside level-2 rows so it's clear which
/// group label they belong to. Consecutive rows form one continuous line.
struct SidebarGuideLine: View {
    var x: CGFloat = SidebarMetrics.guideX
    @Environment(\.theme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.textTertiary.opacity(theme.isDark ? 0.22 : 0.18))
            .frame(width: 1)
            .padding(.leading, x)
            .accessibilityHidden(true)
    }
}

// MARK: - Row Indent Modifiers

extension View {
    /// Indents a row that sits directly under a section header (level 1).
    /// The row's own content should use `SidebarMetrics.rowInnerPadding`
    /// horizontally so its content lines up with group labels.
    func sidebarChildRow() -> some View {
        self
            .padding(.leading, SidebarMetrics.childInset - SidebarMetrics.rowInnerPadding)
            .padding(.trailing, SidebarMetrics.rowTrailing)
    }

    /// Indents a row that sits under a group label (level 2) and draws
    /// the guide line beside it.
    func sidebarNestedRow() -> some View {
        self
            .sidebarGuidedRow()
            .padding(.trailing, SidebarMetrics.rowTrailing)
    }

    /// Indents a row by `offset` + the standard nested inset and draws the
    /// guide line beside it. Used inside containers that already apply their
    /// own horizontal inset (folder rows), where `offset` is the parent's depth.
    func sidebarGuidedRow(offset: CGFloat = 0) -> some View {
        self
            .padding(.leading, offset + SidebarMetrics.nestedRowLeading)
            .background(alignment: .leading) {
                SidebarGuideLine(x: offset + SidebarMetrics.guideX)
            }
    }
}
