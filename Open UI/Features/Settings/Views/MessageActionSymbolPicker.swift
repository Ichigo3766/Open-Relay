import SwiftUI
import SFSafeSymbols

struct MessageActionSymbolPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Binding var selection: String
    @State private var query = ""
    @ScaledMetric(relativeTo: .caption) private var columnWidth = 96
    @ScaledMetric(relativeTo: .caption) private var labelSize = 12
    @ScaledMetric(relativeTo: .title2) private var iconSize = 24

    private static let symbols = SFSymbol.allSymbols
        .map(\.rawValue).sorted().map(MessageActionSymbol.init)

    private var results: [MessageActionSymbol] {
        let terms = MessageActionSymbol.searchTerms(query)
        return terms.isEmpty ? Self.symbols : Self.symbols.filter { $0.matches(terms) }
    }

    var body: some View {
        let visibleSymbols = results
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: columnWidth), spacing: 12)], spacing: 12) {
                ForEach(visibleSymbols) { symbol in
                    Button {
                        selection = symbol.id
                        Haptics.play(.light)
                        dismiss()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: symbol.id)
                                .scaledFont(size: iconSize, weight: .medium)
                                .frame(minHeight: 36)
                            Text(symbol.title)
                                .scaledFont(size: labelSize)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 76)
                        .padding(8)
                        .foregroundStyle(selection == symbol.id ? Color.white : theme.textPrimary)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selection == symbol.id ? theme.brandPrimary : theme.surfaceContainer)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbol.title)
                    .accessibilityValue(symbol.id)
                    .accessibilityAddTraits(selection == symbol.id ? .isSelected : [])
                    .accessibilityIdentifier("shortcutSymbol.\(symbol.id)")
                }
            }
            .padding()
        }
        .overlay {
            if visibleSymbols.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Choose Icon")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search symbols")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
    }
}
