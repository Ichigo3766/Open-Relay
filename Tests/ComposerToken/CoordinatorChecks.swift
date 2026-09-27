import Foundation

// Minimal UIKit/binding interfaces for deterministic delegate re-entry. The
// actual production Coordinator is extracted unchanged by run-coordinator.sh.
protocol UITextViewDelegate: AnyObject {}
final class Position { let offset: Int; init(_ offset: Int) { self.offset = offset } }
final class Selection { let start: Position; init(_ offset: Int) { start = Position(offset) } }
class UITextView {
    var text: String! = ""
    var selectedTextRange: Selection?
    var beginningOfDocument: Position { Position(0) }
    func offset(from: Position, to: Position) -> Int { to.offset - from.offset }
}
final class Placeholder { var isHidden = false }
final class PasteInterceptingTextView: UITextView {
    let placeholderLabel = Placeholder()
    var layoutUpdate: (() -> Void)?
}
final class BindingState { var text = "" }
struct PasteableTextView {
    let storage: BindingState
    var text: String {
        get { storage.text }
        set { storage.text = newValue }
    }
    var onHashTrigger: ((String) -> Void)?
    var onHashDismiss: (() -> Void)?
    var onAtTrigger: ((String) -> Void)?
    var onAtDismiss: (() -> Void)?
    var onSlashTrigger: ((String) -> Void)?
    var onSlashDismiss: (() -> Void)?
    var onDollarTrigger: ((String) -> Void)?
    var onDollarDismiss: (() -> Void)?
    static func recalculateHeight(_ view: PasteInterceptingTextView) { view.layoutUpdate?() }
}

@main struct CoordinatorChecks {
    static func main() {
        var checks = 0
        for symbol in ["@", "#", "/", "$"] {
            for suffix in [" ", "\n", "x"] {
                let old = symbol + "paper", edited = old + suffix
                let view = PasteInterceptingTextView()
                view.text = edited
                view.selectedTextRange = Selection(edited.utf16.count)
                // Reproduce the observed delegate sequence: edited text exists
                // at entry, a re-entrant layout refresh temporarily restores the
                // old value, and SwiftUI applies the new draft on the next turn.
                view.layoutUpdate = {
                    view.text = old
                    view.selectedTextRange = Selection(old.utf16.count)
                }
                let storage = BindingState()
                var events: [String] = []
                let trigger: (String) -> Void = { events.append($0) }
                let dismiss: () -> Void = { events.append("dismiss") }
                var parent = PasteableTextView(storage: storage)
                switch symbol {
                case "@": parent.onAtTrigger = trigger; parent.onAtDismiss = dismiss
                case "#": parent.onHashTrigger = trigger; parent.onHashDismiss = dismiss
                case "/": parent.onSlashTrigger = trigger; parent.onSlashDismiss = dismiss
                default: parent.onDollarTrigger = trigger; parent.onDollarDismiss = dismiss
                }
                let coordinator = PasteableTextView.Coordinator(parent: parent)
                coordinator.textViewDidChange(view)
                let expected = suffix == "x" ? "paperx" : "dismiss"
                guard events == [expected], storage.text == edited else {
                    print("FAIL: delegate must use the edited token despite re-entrant layout")
                    exit(1)
                }
                checks += 1
            }
        }
        print("PASS: \(checks) re-entrant delegate scenarios across four trigger types")
    }
}
