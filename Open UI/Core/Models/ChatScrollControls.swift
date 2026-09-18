/// Floating navigation controls shown while reading earlier chat messages.
enum ChatScrollControls: String, CaseIterable {
    case upDown
    case bottomOnly
    case hidden

    var title: String {
        switch self {
        case .upDown: "Up and Down"
        case .bottomOnly: "Scroll to Bottom"
        case .hidden: "Hidden"
        }
    }
}
