import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}

let defaults = MessageActionPreferences()
let defaultBuiltIns = defaults.order.compactMap { item -> MessageAction? in
    if case .builtIn(let action) = item { return action }
    return nil
}
expect(defaultBuiltIns == MessageAction.allCases, "Default order must match the original built-in action order")
expect(defaults.visibleItems() == defaults.order, "Every built-in action is enabled by default")

let malformed = MessageActionPreferences(order: "share,copy,share,removed,,copy", hidden: "removed,copy,copy")
expect(Array(malformed.order.prefix(2)) == [.builtIn(.share), .builtIn(.copy)], "Saved relative order must survive normalization")
expect(malformed.order.count == MessageAction.allCases.count, "Duplicate/unknown IDs must not duplicate or omit actions")
expect(malformed.hiddenIDs == ["copy"], "Unknown hidden IDs must be ignored")
expect(!malformed.visibleItems().contains(.builtIn(.copy)), "Hidden actions must be omitted")
expect(malformed.visibleItems().first == .builtIn(.share), "Visibility filtering must preserve order")

let onlyCopyAndShare = MessageActionPreferences(hidden: MessageAction.allCases.filter { $0 != .copy && $0 != .share }.map(\.rawValue).joined(separator: ","))
expect(onlyCopyAndShare.visibleItems() == [.builtIn(.copy), .builtIn(.share)], "Users must be able to keep only Copy and Share")
expect(onlyCopyAndShare.visibleItems(speechActive: true) == [.builtIn(.speak), .builtIn(.copy), .builtIn(.share)], "Hiding Speak must not remove an active Stop control")
let hideAll = MessageActionPreferences(hidden: defaults.storedOrder)
expect(hideAll.visibleItems().isEmpty, "All optional built-in actions can be hidden")
expect(hideAll.visibleItems(speechActive: true) == [.builtIn(.speak)], "Stop must remain accessible when all actions are hidden")

let shortcutID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
let shortcut = ShortcutMessageAction(
    id: shortcutID,
    name: "Process Text",
    shortcutName: "Process Assistant Text",
    symbolName: "wand.and.stars"
)
let encodedShortcuts = ShortcutMessageAction.encodeStored([shortcut])
expect(ShortcutMessageAction.decodeStored(encodedShortcuts) == [shortcut], "Shortcut actions must round-trip through local storage")
expect(ShortcutMessageAction.decodeStored("not-json").isEmpty, "Malformed shortcut storage must fail closed")
let duplicateShortcut = ShortcutMessageAction(id: shortcutID, name: "Duplicate", shortcutName: "Duplicate")
let deduplicated = MessageActionPreferences(shortcuts: [shortcut, duplicateShortcut])
expect(deduplicated.order.filter { $0.id == shortcut.storageID }.count == 1, "Duplicate stored Shortcut IDs must be normalized safely")

let mixed = MessageActionPreferences(
    order: "\(shortcut.storageID),share,copy",
    hidden: shortcut.storageID,
    shortcuts: [shortcut]
)
expect(mixed.order.prefix(3) == [.shortcut(shortcut), .builtIn(.share), .builtIn(.copy)], "Shortcut actions must share the saved order with built-ins")
expect(!mixed.visibleItems().contains(.shortcut(shortcut)), "Shortcut actions can be hidden locally")
expect(mixed.storedOrder.contains(shortcut.storageID), "Shortcut IDs must persist in the shared order")

let withoutShortcut = MessageActionPreferences(order: mixed.storedOrder, hidden: mixed.storedHidden)
expect(!withoutShortcut.order.contains(.shortcut(shortcut)), "Deleted shortcut actions must be removed from normalized order")
expect(!withoutShortcut.hiddenIDs.contains(shortcut.storageID), "Deleted shortcut actions must be removed from hidden storage")

let sampleText = "A short response & follow-up"
let shortcutURL = shortcut.runURL(input: sampleText)!
let urlParts = URLComponents(url: shortcutURL, resolvingAgainstBaseURL: false)!
let query = Dictionary(uniqueKeysWithValues: urlParts.queryItems!.map { ($0.name, $0.value ?? "") })
expect(shortcutURL.scheme == "shortcuts" && shortcutURL.host == "run-shortcut", "Shortcut actions must use Apple's run-shortcut URL")
expect(query["name"] == shortcut.shortcutName, "Shortcut name must be URL encoded without changing its value")
expect(query["input"] == "text" && query["text"] == sampleText, "Assistant text must be passed as direct Shortcut input")

let suite = "MessageActionPreferencesTests." + UUID().uuidString
let storage = UserDefaults(suiteName: suite)!
defer { storage.removePersistentDomain(forName: suite) }
storage.set(malformed.storedOrder, forKey: MessageActionPreferences.orderKey)
storage.set(malformed.storedHidden, forKey: MessageActionPreferences.hiddenKey)
let restored = MessageActionPreferences(
    order: storage.string(forKey: MessageActionPreferences.orderKey)!,
    hidden: storage.string(forKey: MessageActionPreferences.hiddenKey)!
)
expect(restored.order == malformed.order, "Reordering must round-trip through storage")
expect(restored.hiddenIDs == malformed.hiddenIDs, "Visibility must round-trip through storage")
var shownAgain = restored
shownAgain.setVisible(true, for: .builtIn(.copy))
expect(shownAgain.visibleItems().prefix(2) == [.builtIn(.share), .builtIn(.copy)], "Re-enabling must retain the saved position")
let reset = MessageActionPreferences(order: "", hidden: "")
expect(reset.order == defaults.order && reset.hiddenIDs.isEmpty, "Reset must restore visibility and order")

// User edits must preserve identity, position, and visibility across a relaunch.
var edited = shortcut
edited.name = "Renamed Button"
edited.shortcutName = "New Shortcut + café & 🪁"
edited.symbolName = "heart.fill"
let afterEdit = MessageActionPreferences(order: mixed.storedOrder, hidden: mixed.storedHidden, shortcuts: [edited])
expect(afterEdit.order.first == .shortcut(edited), "Editing must keep the saved position and use the new fields")
expect(!afterEdit.isVisible(.shortcut(edited)), "Editing must preserve hidden state")
let resetWithShortcut = MessageActionPreferences(shortcuts: [edited])
expect(resetWithShortcut.order.last == .shortcut(edited) && resetWithShortcut.isVisible(.shortcut(edited)), "Reset must retain custom actions and restore their visibility")
var restricted = MessageActionPreferences(order: "share,speak,copy,\(edited.storageID)", shortcuts: [edited])
let oldOrder = restricted.order
restricted.reorder([.shortcut(edited), .builtIn(.copy), .builtIn(.share)])
expect(Array(restricted.order.prefix(4)) == [.shortcut(edited), .builtIn(.speak), .builtIn(.copy), .builtIn(.share)], "Reordering must leave server-omitted actions in their original slots")
expect(Array(restricted.order.dropFirst(4)) == Array(oldOrder.dropFirst(4)), "Reordering a subset must not move unrelated actions")
let reordered = restricted.order
restricted.reorder([])
expect(restricted.order == reordered, "Reordering an empty displayed list must be a no-op")
for invalid in ["", "null", "{}", "[{}]", "[", "123"] {
    expect(ShortcutMessageAction.decodeStored(invalid).isEmpty, "Invalid persisted JSON must not crash")
}

let inputs = ["", "+ & = ? # % / : ;", "line one\nline two\r\n\tindented", "café 日本語 العربية 🪁 👩🏽‍💻",
              "https://example.test/?text=one+two&input=clipboard#fragment", "\"quoted\" \\ backslash",
              String(repeating: "Long response 🪁 + % &\n", count: 10_000)]
for input in inputs {
    let url = edited.runURL(input: input)!
    let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    expect(parts.fragment == nil && parts.queryItems?.count == 3, "Input must not inject URL components")
    expect(parts.queryItems?.first(where: { $0.name == "name" })?.value == edited.shortcutName, "Shortcut names must survive encoding exactly")
    expect(parts.queryItems?.first(where: { $0.name == "text" })?.value == input, "Multiline, Unicode, reserved characters, and long text must survive encoding exactly")
}

// Deterministic mixed-order cases catch lost, duplicated, or resurrected actions.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64 = 42
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
var generator = SeededGenerator()
let manyShortcuts = (0..<20).map { index in
    ShortcutMessageAction(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                          name: "Button \(index)", shortcutName: "Shortcut \(index)")
}
for _ in 0..<200 {
    let allItems = MessageActionPreferences(shortcuts: manyShortcuts).order.shuffled(using: &generator)
    let hiddenIDs = Set(allItems.filter { _ in Bool.random(using: &generator) }.map(\.id))
    let savedOrder = (allItems.map(\.id) + ["unknown", allItems[0].id]).joined(separator: ",")
    let savedHidden = (Array(hiddenIDs) + ["unknown"]).joined(separator: ",")
    let loaded = MessageActionPreferences(order: savedOrder, hidden: savedHidden, shortcuts: manyShortcuts)
    expect(loaded.order == allItems, "Normalizing must preserve the exact valid mixed order")
    expect(loaded.hiddenIDs == hiddenIDs, "Normalizing must preserve exactly the known hidden IDs")
    expect(loaded.visibleItems() == allItems.filter { !hiddenIDs.contains($0.id) }, "Visibility must preserve relative order")
    let reloaded = MessageActionPreferences(order: loaded.storedOrder, hidden: loaded.storedHidden, shortcuts: manyShortcuts)
    expect(reloaded.order == loaded.order && reloaded.hiddenIDs == loaded.hiddenIDs, "Repeated loading must be idempotent")
    let survivors = Array(manyShortcuts.dropFirst(10))
    let deletedIDs = Set(manyShortcuts.prefix(10).map(\.storageID))
    let afterDelete = MessageActionPreferences(order: loaded.storedOrder, hidden: loaded.storedHidden, shortcuts: survivors)
    expect(afterDelete.order == allItems.filter { !deletedIDs.contains($0.id) }, "Deleting must preserve the order of all survivors")
    expect(afterDelete.hiddenIDs.isDisjoint(with: deletedIDs), "Deleting must remove every obsolete visibility preference")
    let displayed = allItems.filter { _ in Bool.random(using: &generator) }
    let displayedIDs = Set(displayed.map(\.id))
    let moved = displayed.shuffled(using: &generator)
    var afterMove = loaded
    afterMove.reorder(moved)
    expect(afterMove.order.filter { displayedIDs.contains($0.id) } == moved, "The displayed subset must follow the requested order")
    expect(allItems.indices.filter { !displayedIDs.contains(allItems[$0].id) }.allSatisfy { afterMove.order[$0] == allItems[$0] }, "Server-omitted actions must retain their exact slots")
    expect(afterMove.hiddenIDs == hiddenIDs, "Reordering must not change visibility")
}
let documentSymbol = MessageActionSymbol("doc.text.fill")
expect(documentSymbol.id == "doc.text.fill", "Display labels must not change the system symbol name")
expect(documentSymbol.title == "Document Text Filled", "Common abbreviations and separators must have readable labels")
expect(MessageActionSymbol("paperplane.circle").title == "Paper Plane Circle", "Compound names must have readable words")
for query in ["", " \n\t", "DOC.TEXT", "document filled", " FILLED\nDocument ", "text doc"] {
    expect(documentSymbol.matches(MessageActionSymbol.searchTerms(query)), "Search must match raw names, labels, whitespace, and reordered words: \(query)")
}
for query in ["not-a-symbol", "document star", "🪁"] {
    expect(!documentSymbol.matches(MessageActionSymbol.searchTerms(query)), "Every search term must match: \(query)")
}
expect(MessageActionSymbol("magnifyingglass").matches(MessageActionSymbol.searchTerms("search")), "Search must find the common search icon")
expect(MessageActionSymbol("paperplane.fill").matches(MessageActionSymbol.searchTerms("paper plane")), "Search must support readable compound names")
expect(MessageActionSymbol("new.symbol.variant").title == "New Symbol Variant", "Unrecognized names must still have useful labels")
for name in ["book.closed.fill", "person.crop.circle.badge.checkmark", "character.ja", "waveform.path.ecg"] {
    let selected = ShortcutMessageAction(name: "Process Text", shortcutName: "Process Assistant Text", symbolName: name)
    expect(ShortcutMessageAction.decodeStored(ShortcutMessageAction.encodeStored([selected])) == [selected], "Any selected catalog name must persist unchanged")
}
print("MessageActionPreferences: \(checks) checks passed")
