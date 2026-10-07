import SwiftUI

// MARK: - Model Picker Content: List, Empty & Loading States

extension ModelPickerContent {

    @ViewBuilder
    var modelList: some View {
        if models.isEmpty {
            loadingState
        } else if visibleModels.isEmpty {
            emptyState
        } else {
            let rowCount = (currentModel == nil ? 0 : 1) + pinnedModels.count + remainingModels.count
            List {
                if let current = currentModel {
                    Section { modelRow(current, index: 2) } header: { sectionHeader("Currently Selected") }
                }
                if !pinnedModels.isEmpty {
                    Section {
                        ForEach(Array(pinnedModels.enumerated()), id: \.element.id) { i, m in
                            modelRow(m, index: 3 + i)
                        }
                    } header: { sectionHeader("Pinned") }
                }
                if !remainingModels.isEmpty {
                    Section {
                        ForEach(Array(remainingModels.enumerated()), id: \.element.id) { i, m in
                            modelRow(m, index: 3 + pinnedModels.count + i)
                        }
                    } header: { sectionHeader("All Models") }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .textCase(nil)
            // Pinning / filtering glides rows between sections instead of jumping.
            .animation(MicroAnimation.snappy, value: pinnedModelIds)
            .animation(MicroAnimation.snappy, value: rowCount)
        }
    }

    func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }

    // MARK: Empty / loading

    var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().tint(theme.brandPrimary)
            Text("Loading models\u{2026}")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 28)
                .foregroundStyle(theme.textTertiary)
            Text(searchText.isEmpty ? "No models" : "No results for \u{201C}\(searchText)\u{201D}")
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        Haptics.play(.light)
                    } label: {
                        Text("Clear search").scaledFont(size: 13).foregroundStyle(theme.brandPrimary)
                    }
                    .buttonStyle(.pressable)
                }
                if selectedTag != nil || selectedConnection != nil {
                    Button {
                        withAnimation(MicroAnimation.quick) { selectedTag = nil; selectedConnection = nil }
                    } label: {
                        Text("Clear filters").scaledFont(size: 13).foregroundStyle(theme.brandPrimary)
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 32)
    }
}
