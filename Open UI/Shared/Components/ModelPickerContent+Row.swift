import SwiftUI

// MARK: - Model Picker Content: Row

extension ModelPickerContent {

    func modelRow(_ model: AIModel, index: Int) -> some View {
        let isPinned = pinnedModelIds.contains(model.id)
        let isSelected = model.id == selectedModelId

        return HStack(spacing: 0) {
            selectButton(model)

            if let onTogglePin {
                Button {
                    Haptics.play(.light)
                    onTogglePin(model.id)
                } label: {
                    Image(systemName: isPinned ? "star.fill" : "star")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(isPinned ? Color.yellow : theme.textTertiary)
                        .contentTransition(.symbolEffect(.replace))
                        .animation(MicroAnimation.quick, value: isPinned)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(isPinned ? "Unpin" : "Pin")
            }

            if isAdmin, let onEdit {
                Button {
                    Haptics.play(.light)
                    onEdit(model)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 30, height: 30)
                        .background(theme.surfaceContainer.opacity(0.7))
                        .clipShape(Circle())
                        .frame(width: 38, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Edit model")
            }

            // Fixed-width slot so rows line up whether or not they're selected.
            Image(systemName: "checkmark")
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
                .opacity(isSelected ? 1 : 0)
                .scaleEffect(isSelected ? 1 : 0.6)
                .animation(MicroAnimation.snappy, value: isSelected)
                .frame(width: 34)
        }
        .background(isSelected ? theme.brandPrimary.opacity(theme.isDark ? 0.12 : 0.08) : Color.clear)
        .contextMenu { rowMenu(model, isPinned: isPinned) }
        .modifier(MorphRowReveal(isRevealed: contentRevealed, index: min(index, 12)))
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(theme.divider.opacity(0.4))
        .alignmentGuide(.listRowSeparatorLeading) { _ in 16 + 36 + 12 }
    }

    /// Main tap target (select). The pin / edit buttons are siblings, not children,
    /// so pinning can never select the model by accident.
    private func selectButton(_ model: AIModel) -> some View {
        Button {
            Haptics.play(.light)
            onSelect(model)
        } label: {
            HStack(spacing: 12) {
                ModelAvatar(
                    size: 36,
                    imageURL: model.resolveAvatarURL(baseURL: serverBaseURL),
                    label: model.shortName,
                    authToken: authToken
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    subtitle(for: model)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func rowMenu(_ model: AIModel, isPinned: Bool) -> some View {
        if let onTogglePin {
            Button { onTogglePin(model.id) } label: {
                Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "star.slash" : "star")
            }
        }
        Button {
            UIPasteboard.general.string = model.id
            Haptics.notify(.success)
        } label: {
            Label("Copy Model ID", systemImage: "doc.on.doc")
        }
        if isAdmin, let onEdit {
            Button { onEdit(model) } label: {
                Label("Edit Model", systemImage: "slider.horizontal.3")
            }
        }
    }

    @ViewBuilder
    func subtitle(for model: AIModel) -> some View {
        let desc = model.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ctx: String? = {
            guard let c = model.contextLength, c > 0 else { return nil }
            if c >= 1_000_000 { return "\(c / 1_000_000)M" }
            if c >= 1_000 { return "\(c / 1_000)K" }
            return "\(c)"
        }()
        if !desc.isEmpty || ctx != nil {
            HStack(spacing: 6) {
                if let ctx {
                    Text(ctx)
                        .scaledFont(size: 10, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.surfaceContainer.opacity(0.9)))
                }
                if !desc.isEmpty {
                    Text(desc)
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}
