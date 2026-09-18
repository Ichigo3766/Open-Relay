import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}

let defaults = MessageActionPreferences()
expect(defaults.order == MessageAction.allCases, "Default order must match the original built-in action order")
expect(defaults.visibleActions() == MessageAction.allCases, "Every built-in action is enabled by default")

let malformed = MessageActionPreferences(order: "share,copy,share,removed,,copy", hidden: "removed,copy,copy")
expect(Array(malformed.order.prefix(2)) == [.share, .copy], "Saved relative order must survive normalization")
expect(malformed.order.count == MessageAction.allCases.count, "Duplicate/unknown IDs must not duplicate or omit actions")
expect(Set(malformed.order) == Set(MessageAction.allCases), "New actions must be appended")
expect(malformed.hidden == [.copy], "Unknown hidden IDs must be ignored")
expect(!malformed.visibleActions().contains(.copy), "Hidden actions must be omitted")
expect(malformed.visibleActions().first == .share, "Visibility filtering must preserve order")

let onlyCopyAndShare = MessageActionPreferences(hidden: MessageAction.allCases.filter { $0 != .copy && $0 != .share }.map(\.rawValue).joined(separator: ","))
expect(onlyCopyAndShare.visibleActions() == [.copy, .share], "Users must be able to keep only Copy and Share")
expect(onlyCopyAndShare.visibleActions(speechActive: true) == [.speak, .copy, .share], "Hiding Speak must not remove an active Stop control")
let hideAll = MessageActionPreferences(hidden: defaults.storedOrder)
expect(hideAll.visibleActions().isEmpty, "All optional built-in actions can be hidden")
expect(hideAll.visibleActions(speechActive: true) == [.speak], "Stop must remain accessible when all actions are hidden")

let suite = "MessageActionPreferencesTests." + UUID().uuidString
let storage = UserDefaults(suiteName: suite)!
defer { storage.removePersistentDomain(forName: suite) }
storage.set(malformed.storedOrder, forKey: MessageActionPreferences.orderKey)
storage.set(malformed.storedHidden, forKey: MessageActionPreferences.hiddenKey)
let restored = MessageActionPreferences(order: storage.string(forKey: MessageActionPreferences.orderKey)!, hidden: storage.string(forKey: MessageActionPreferences.hiddenKey)!)
expect(restored.order == malformed.order, "Reordering must round-trip through storage")
expect(restored.hidden == malformed.hidden, "Visibility must round-trip through storage")
var shownAgain = restored
shownAgain.hidden.remove(.copy)
expect(shownAgain.visibleActions().prefix(2) == [.share, .copy], "Re-enabling must retain the saved position")
let reset = MessageActionPreferences(order: "", hidden: "")
expect(reset.order == defaults.order && reset.hidden.isEmpty, "Reset must restore visibility and order")
print("MessageActionPreferences: \(checks) checks passed")
