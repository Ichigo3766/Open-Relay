import SwiftUI

// MARK: - Card Attachment Row

struct CardAttachmentRow: View {
    let item: KnowledgeItem
    let selectedIDs: Set<String>?
    let onSelect: (KnowledgeItem) -> Void
    var onBrowse: ((KnowledgeItem) -> Void)?

    @Environment(\.theme) private var theme

    private var isSelected: Bool { selectedIDs?.contains(item.id) == true }

    private var trailingIcon: String {
        guard selectedIDs != nil else { return "plus.circle" }
        return isSelected ? "checkmark.circle.fill" : "circle"
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                Haptics.play(.light)
                onSelect(item)
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: item.iconName)
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(theme.brandPrimary.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(2)
                        if let description = item.description, !description.isEmpty {
                            Text(description)
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: trailingIcon)
                        .scaledFont(size: 18, weight: .medium)
                        .foregroundStyle(isSelected ? theme.brandPrimary : theme.textTertiary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MorphPressStyle(scale: 0.97))
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if item.type == .collection, let onBrowse {
                Button {
                    Haptics.play(.light)
                    onBrowse(item)
                } label: {
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MorphPressStyle())
                .accessibilityLabel("Browse \(item.name)")
            }
        }
        .padding(Spacing.sm)
        .background(isSelected
            ? theme.brandPrimary.opacity(theme.isDark ? 0.22 : 0.12)
            : theme.surfaceContainer.opacity(theme.isDark ? 0.32 : 0.12))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
            .strokeBorder(isSelected ? theme.brandPrimary.opacity(0.5) : theme.cardBorder.opacity(0.5),
                          lineWidth: 0.5))
        .animation(MicroAnimation.snappy, value: isSelected)
    }
}
