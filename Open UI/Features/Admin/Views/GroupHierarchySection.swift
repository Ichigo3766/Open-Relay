import SwiftUI

/// Group editor: parent group (nested groups) and default models for
/// members' new chats. Members of an inner group also get everything shared with
/// the parent groups above it, and their permissions.
struct GroupHierarchySection: View {
    @Bindable var viewModel: AdminGroupsViewModel

    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @State private var showModelPicker = false

    private var candidates: [GroupDetail] {
        viewModel.parentCandidates(for: viewModel.editingGroup?.id)
    }

    private var parentName: String {
        candidates.first { $0.id == viewModel.editParentGroupId }?.name ?? String(localized: "None")
    }

    private var models: [AIModel] { dependencies.activeChatStore.cachedModels }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("HIERARCHY & DEFAULTS")
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .tracking(0.8)
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.bottom, Spacing.sm)

            VStack(spacing: 0) {
                parentRow
                if !viewModel.editParentGroupId.isEmpty {
                    let chain = viewModel.ancestors(ofParent: viewModel.editParentGroupId)
                    Text("Members also inherit access and permissions from: \(chain.map(\.name).joined(separator: " → "))")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.md)
                        .padding(.bottom, 10)
                }
                Divider().padding(.horizontal, Spacing.md)
                defaultModelsRow
            }
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .strokeBorder(theme.cardBorder, lineWidth: 0.5)
            )
            .padding(.horizontal, Spacing.screenPadding)
        }
        .sheet(isPresented: $showModelPicker) {
            GroupDefaultModelsPicker(models: models, selection: $viewModel.editDefaultModels)
        }
    }

    private var parentRow: some View {
        HStack {
            Text("Parent Group")
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Menu {
                Button("None") { viewModel.editParentGroupId = "" }
                ForEach(candidates) { group in
                    Button {
                        viewModel.editParentGroupId = group.id
                    } label: {
                        if viewModel.editParentGroupId == group.id {
                            Label(group.name, systemImage: "checkmark")
                        } else {
                            Text(group.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(parentName).scaledFont(size: 14).foregroundStyle(theme.textTertiary)
                    Image(systemName: "chevron.up.chevron.down")
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 12)
    }

    private var defaultModelsRow: some View {
        Button {
            showModelPicker = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Default Models")
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textPrimary)
                    Text(viewModel.editDefaultModels.isEmpty
                         ? String(localized: "Use the global default")
                         : viewModel.editDefaultModels.map(modelName).joined(separator: ", "))
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modelName(_ id: String) -> String {
        models.first { $0.id == id }?.name ?? id
    }
}
