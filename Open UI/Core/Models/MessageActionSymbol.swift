import Foundation

nonisolated struct MessageActionSymbol: Identifiable, Sendable {
    let id: String
    let title: String
    private let searchText: String

    init(_ name: String) {
        id = name
        let words = name.split(separator: ".").map { part in
            Self.readableWords[String(part)] ?? String(part)
        }
        title = words.joined(separator: " ").capitalized
        searchText = "\(name) \(title)".lowercased()
    }

    func matches(_ terms: [String]) -> Bool {
        terms.allSatisfy { searchText.contains($0) }
    }

    static func searchTerms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static let readableWords = [
        "doc": "document", "fill": "filled", "magnifyingglass": "magnifying glass search",
        "paperplane": "paper plane", "arrowtriangle": "arrow triangle",
        "arrowshape": "arrow shape", "checkmark": "check mark", "xmark": "x mark",
        "exclamationmark": "exclamation mark", "questionmark": "question mark",
        "plusminus": "plus minus", "textformat": "text format"
    ]
}
