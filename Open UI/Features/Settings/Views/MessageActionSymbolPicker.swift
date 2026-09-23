import SwiftUI

struct MessageActionSymbolPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Binding var selection: String
    @State private var query = ""
    @ScaledMetric(relativeTo: .caption) private var columnWidth = 96
    @ScaledMetric(relativeTo: .caption) private var labelSize = 12
    @ScaledMetric(relativeTo: .title2) private var iconSize = 24

    /// Curated SF Symbol names suitable for message action buttons.
    private static let symbolNames: [String] = [
        "bolt.fill", "wand.and.stars", "sparkles", "star.fill", "heart.fill",
        "bookmark.fill", "tag.fill", "flag.fill", "bell.fill", "pin.fill",
        "link", "paperclip", "paperplane.fill", "tray.fill", "archivebox.fill",
        "trash.fill", "folder.fill", "doc.fill", "doc.text.fill", "doc.on.doc.fill",
        "square.and.arrow.up.fill", "square.and.arrow.down.fill", "arrow.clockwise",
        "arrow.uturn.left", "arrow.triangle.2.circlepath", "repeat", "shuffle",
        "play.fill", "pause.fill", "stop.fill", "speaker.wave.2.fill",
        "mic.fill", "video.fill", "camera.fill", "photo.fill",
        "magnifyingglass", "pencil", "highlighter", "scissors",
        "paintbrush.fill", "paintpalette.fill", "eyedropper.full",
        "wand.and.rays", "wand.and.rays.inverse", "lasso",
        "crop", "rotate.right.fill", "rotate.left.fill",
        "eye.fill", "eye.slash.fill", "lock.fill", "lock.open.fill",
        "key.fill", "shield.fill", "person.fill", "person.2.fill",
        "person.crop.circle.fill", "figure.walk", "figure.stand",
        "hand.thumbsup.fill", "hand.thumbsdown.fill", "hand.raised.fill",
        "hands.clap.fill", "gift.fill", "cart.fill", "bag.fill",
        "creditcard.fill", "banknote.fill", "dollarsign.circle.fill",
        "chart.bar.fill", "chart.pie.fill", "chart.line.uptrend.xyaxis",
        "calendar", "clock.fill", "alarm.fill", "timer",
        "location.fill", "map.fill", "globe", "antenna.radiowaves.left.and.right",
        "wifi", "bluetooth", "network", "server.rack",
        "cpu.fill", "memorychip.fill", "externaldrive.fill",
        "iphone", "ipad", "macmini.fill", "applewatch",
        "keyboard.fill", "computermouse.fill", "printer.fill",
        "lightbulb.fill", "flame.fill", "drop.fill", "snowflake",
        "cloud.fill", "sun.max.fill", "moon.fill", "wind",
        "leaf.fill", "tree.fill", "pawprint.fill", "ant.fill",
        "function", "sum", "plus", "minus", "multiply", "divide",
        "equal", "lessthan", "greaterthan", "number", "percent",
        "checkmark", "checkmark.circle.fill", "checkmark.seal.fill",
        "xmark", "xmark.circle.fill", "questionmark.circle.fill",
        "exclamationmark.circle.fill", "exclamationmark.triangle.fill",
        "info.circle.fill", "ellipsis.circle.fill", "ellipsis",
        "square.grid.2x2.fill", "square.grid.3x3.fill", "list.bullet",
        "text.alignleft", "text.aligncenter", "text.alignright",
        "bold", "italic", "underline", "strikethrough",
        "textformat", "character", "abc",
        "arrow.right.circle.fill", "arrow.left.circle.fill",
        "arrow.up.circle.fill", "arrow.down.circle.fill",
        "chevron.right", "chevron.left", "chevron.up", "chevron.down",
        "return", "escape", "delete.left.fill", "command",
        "hammer.fill", "wrench.fill", "screwdriver.fill", "gear",
        "gearshape.fill", "slider.horizontal.3", "tuningfork",
        "music.note", "music.note.list", "music.mic", "headphones",
        "radio.fill", "tv.fill", "display", "desktopcomputer",
        "gamecontroller.fill", "puzzlepiece.fill", "die.face.5.fill",
        "sportscourt.fill", "trophy.fill", "medal.fill", "rosette",
        "graduationcap.fill", "books.vertical.fill", "book.fill",
        "newspaper.fill", "magazine",
        "envelope.fill", "envelope.open.fill", "message.fill",
        "bubble.left.fill", "bubble.right.fill", "text.bubble.fill",
        "phone.fill", "phone.arrow.up.right.fill", "phone.arrow.down.left.fill",
        "faceid", "touchid", "person.badge.key.fill",
        "cross.fill", "cross.case.fill", "pills.fill", "bandage.fill",
        "brain.head.profile", "lungs.fill", "heart.text.square.fill",
        "fork.knife", "cup.and.saucer.fill", "wineglass.fill",
        "house.fill", "building.fill", "building.2.fill",
        "car.fill", "bicycle", "airplane", "tram.fill",
        "ferry.fill", "sailboat.fill", "figure.pool.swim",
        "cart.badge.plus", "bag.badge.plus"
    ]

    private static let symbols = symbolNames.map(MessageActionSymbol.init)

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
                                .font(.system(size: iconSize, weight: .medium))
                                .frame(minHeight: 36)
                            Text(symbol.title)
                                .font(.system(size: labelSize))
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
