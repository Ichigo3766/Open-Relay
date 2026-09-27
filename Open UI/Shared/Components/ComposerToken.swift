import Foundation

/// The single trigger token immediately before a UIKit text cursor.
struct ComposerToken: Equatable {
    let symbol: Character
    let query: String

    init?(text: String, utf16Offset: Int) {
        guard utf16Offset >= 0,
              let offset = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset,
                                           limitedBy: text.utf16.endIndex),
              let end = String.Index(offset, within: text) else { return nil }
        var start = end
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous].isWhitespace { break }
            start = previous
        }
        let token = text[start..<end]
        guard let symbol = token.first, "#@/$".contains(symbol) else { return nil }
        let query = token.dropFirst()
        // A repeated trigger inside the word was not a valid token previously.
        guard !query.contains(symbol) else { return nil }
        self.symbol = symbol
        self.query = String(query)
    }
}
