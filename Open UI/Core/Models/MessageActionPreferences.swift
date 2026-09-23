import Foundation

/// Stable identifiers for the built-in assistant message actions.
enum MessageAction: String, CaseIterable, Identifiable {
    case speak, copy, share, edit, regenerate, continueResponse, fork, deleteVersion, usage, thumbsUp, thumbsDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speak: String(localized: "Speak")
        case .copy: String(localized: "Copy")
        case .share: String(localized: "Share")
        case .edit: String(localized: "Edit response")
        case .regenerate: String(localized: "Regenerate")
        case .continueResponse: String(localized: "Continue response")
        case .fork: String(localized: "Fork chat")
        case .deleteVersion: String(localized: "Delete version")
        case .usage: String(localized: "Token usage")
        case .thumbsUp: String(localized: "Thumbs up")
        case .thumbsDown: String(localized: "Thumbs down")
        }
    }

    var iconName: String {
        switch self {
        case .speak: "speaker.wave.2"
        case .copy: "doc.on.doc"
        case .share: "square.and.arrow.up"
        case .edit: "pencil"
        case .regenerate: "arrow.clockwise"
        case .continueResponse: "play.fill"
        case .fork: "arrow.branch"
        case .deleteVersion: "trash"
        case .usage: "info.circle"
        case .thumbsUp: "hand.thumbsup"
        case .thumbsDown: "hand.thumbsdown"
        }
    }
}

/// A user-created action that runs an Apple Shortcut with the assistant message as text input.
/// These actions are stored only in local app preferences and are never sent to the server.
struct ShortcutMessageAction: Codable, Identifiable, Hashable {
    static let defaultSymbolName = "bolt.fill"

    let id: UUID
    var name: String
    var shortcutName: String
    var symbolName: String

    init(
        id: UUID = UUID(),
        name: String = "",
        shortcutName: String = "",
        symbolName: String = ShortcutMessageAction.defaultSymbolName
    ) {
        self.id = id
        self.name = name
        self.shortcutName = shortcutName
        self.symbolName = symbolName
    }

    var storageID: String { "shortcut:\(id.uuidString.lowercased())" }

    /// Builds Apple's documented `shortcuts://run-shortcut` URL with direct text input.
    func runURL(input: String) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: shortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: input)
        ]
        return components.url
    }

    static func decodeStored(_ value: String) -> [ShortcutMessageAction] {
        guard let data = value.data(using: .utf8),
              let actions = try? JSONDecoder().decode([ShortcutMessageAction].self, from: data)
        else { return [] }
        return actions
    }

    static func encodeStored(_ actions: [ShortcutMessageAction]) -> String {
        guard let data = try? JSONEncoder().encode(actions),
              let value = String(data: data, encoding: .utf8)
        else { return "[]" }
        return value
    }
}

/// An entry in the locally ordered assistant action list.
enum MessageActionItem: Identifiable, Hashable {
    case builtIn(MessageAction)
    case shortcut(ShortcutMessageAction)

    var id: String {
        switch self {
        case .builtIn(let action): action.rawValue
        case .shortcut(let action): action.storageID
        }
    }
}

/// Device-local preferences; message availability and server permissions still apply.
struct MessageActionPreferences {
    static let orderKey = "messageActionOrder"
    static let hiddenKey = "hiddenMessageActions"
    static let shortcutsKey = "shortcutMessageActions"

    var order: [MessageActionItem]
    var hiddenIDs: Set<String>

    init(order: String = "", hidden: String = "", shortcuts: [ShortcutMessageAction] = []) {
        let candidates = MessageAction.allCases.map(MessageActionItem.builtIn)
            + shortcuts.map(MessageActionItem.shortcut)
        var allItems: [MessageActionItem] = []
        var itemsByID: [String: MessageActionItem] = [:]
        for item in candidates where itemsByID[item.id] == nil {
            allItems.append(item)
            itemsByID[item.id] = item
        }

        var seen = Set<String>()
        self.order = (order.split(separator: ",").compactMap { itemsByID[String($0)] }
            + allItems).filter { seen.insert($0.id).inserted }
        self.hiddenIDs = Set(hidden.split(separator: ",").map(String.init)).intersection(itemsByID.keys)
    }

    var storedOrder: String { order.map(\.id).joined(separator: ",") }
    var storedHidden: String { order.filter { hiddenIDs.contains($0.id) }.map(\.id).joined(separator: ",") }

    func isVisible(_ item: MessageActionItem) -> Bool {
        !hiddenIDs.contains(item.id)
    }

    mutating func setVisible(_ visible: Bool, for item: MessageActionItem) {
        if visible { hiddenIDs.remove(item.id) }
        else { hiddenIDs.insert(item.id) }
    }

    /// Reorders the displayed subset without moving actions omitted by server permissions.
    mutating func reorder(_ items: [MessageActionItem]) {
        let ids = Set(items.map(\.id))
        var replacements = items.makeIterator()
        order = order.map { ids.contains($0.id) ? (replacements.next() ?? $0) : $0 }
    }

    func visibleItems(speechActive: Bool = false) -> [MessageActionItem] {
        order.filter { item in
            if case .builtIn(.speak) = item, speechActive { return true }
            return !hiddenIDs.contains(item.id)
        }
    }

    // Backward-compatible wrapper used by existing ChatDetailView code
    func visibleActions(speechActive: Bool = false) -> [MessageAction] {
        visibleItems(speechActive: speechActive).compactMap {
            if case .builtIn(let action) = $0 { return action }
            return nil
        }
    }
}
