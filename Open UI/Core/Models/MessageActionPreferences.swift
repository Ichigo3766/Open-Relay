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
}

/// Device-local preferences; message availability and server permissions still apply.
struct MessageActionPreferences {
    static let orderKey = "messageActionOrder"
    static let hiddenKey = "hiddenMessageActions"

    var order: [MessageAction]
    var hidden: Set<MessageAction>

    init(order: String = "", hidden: String = "") {
        var seen = Set<MessageAction>()
        self.order = (order.split(separator: ",").compactMap { MessageAction(rawValue: String($0)) }
            + MessageAction.allCases).filter { seen.insert($0).inserted }
        self.hidden = Set(hidden.split(separator: ",").compactMap { MessageAction(rawValue: String($0)) })
    }

    var storedOrder: String { order.map(\.rawValue).joined(separator: ",") }
    var storedHidden: String { MessageAction.allCases.filter { hidden.contains($0) }.map(\.rawValue).joined(separator: ",") }

    func visibleActions(speechActive: Bool = false) -> [MessageAction] {
        order.filter { !hidden.contains($0) || ($0 == .speak && speechActive) }
    }
}
