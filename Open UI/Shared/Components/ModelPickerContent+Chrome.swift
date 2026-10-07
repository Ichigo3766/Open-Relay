import SwiftUI

// MARK: - Model Picker Content: Header, Search, Filter Pills

extension ModelPickerContent {

    var header: some View {
        HStack(spacing: 6) {
            Text("Models")
                .scaledFont(size: 17, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            if !models.isEmpty {
                Text("\(filteredModels.count)")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .contentTransition(.numericText())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.surfaceContainer))
                    .animation(MicroAnimation.quick, value: filteredModels.count)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .modifier(MorphRowReveal(isRevealed: contentRevealed, index: 0))
    }

    // MARK: Search

    var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textTertiary)

            TextField("Search\u{2026}", text: $searchText)
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
                .tint(theme.brandPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($searchFocused)
                .submitLabel(.search)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.pressable)
                .transition(.opacity.combined(with: .scale))
            }
        }
        // Outside the `if`, so the clear button animates in as well as out.
        .animation(MicroAnimation.quick, value: searchText.isEmpty)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surfaceContainer.opacity(theme.isDark ? 0.6 : 0.8))
        )
    }

    // MARK: Filter pills

    var filterPillsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterPill(label: "All",
                           isSelected: selectedTag == nil && selectedConnection == nil,
                           systemIcon: nil) {
                    withAnimation(MicroAnimation.quick) { selectedTag = nil; selectedConnection = nil }
                    Haptics.play(.light)
                }

                ForEach(allConnections, id: \.self) { conn in
                    filterPill(label: conn.capitalized,
                               isSelected: selectedConnection == conn && selectedTag == nil,
                               systemIcon: connectionIcon(conn)) {
                        withAnimation(MicroAnimation.quick) {
                            selectedConnection = (selectedConnection == conn) ? nil : conn
                            selectedTag = nil
                        }
                        Haptics.play(.light)
                    }
                }

                ForEach(allTags, id: \.self) { tag in
                    filterPill(label: tag,
                               isSelected: selectedTag == tag && selectedConnection == nil,
                               systemIcon: "number") {
                        withAnimation(MicroAnimation.quick) {
                            selectedTag = (selectedTag == tag) ? nil : tag
                            selectedConnection = nil
                        }
                        Haptics.play(.light)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    func connectionIcon(_ conn: String) -> String {
        switch conn.lowercased() {
        case "external": return "link"
        case "internal": return "server.rack"
        default: return "cpu"
        }
    }

    func filterPill(label: String, isSelected: Bool, systemIcon: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = systemIcon {
                    Image(systemName: icon).scaledFont(size: 10, weight: .medium)
                }
                Text(label).scaledFont(size: 12, weight: isSelected ? .semibold : .regular)
            }
            .foregroundStyle(isSelected ? theme.brandPrimary : theme.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isSelected ? theme.brandPrimary.opacity(0.14) : theme.surfaceContainer.opacity(0.7))
            )
            .overlay(
                Capsule().strokeBorder(isSelected ? theme.brandPrimary.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.pressable)
    }
}
