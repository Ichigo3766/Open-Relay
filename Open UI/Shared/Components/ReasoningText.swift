import Litext
import SwiftUI

/// Keep continuous text and selection while drawing only the visible viewport.
struct ReasoningText: UIViewRepresentable {
    let text: String
    var fontSize: CGFloat = 12
    var color: UIColor = .label

    func makeUIView(context _: Context) -> LTXLabel {
        let label = LTXLabel()
        label.isSelectable = true
        label.isAccessibilityElement = true
        return label
    }

    func updateUIView(_ label: LTXLabel, context _: Context) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
        label.accessibilityLabel = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LTXLabel, context _: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        // Resolve height before placement; a later intrinsic-size correction can
        // trigger the chat's bottom-follow logic while expanding reasoning.
        uiView.preferredMaxLayoutWidth = width
        return CGSize(width: width, height: uiView.intrinsicContentSize.height)
    }
}
