import Litext
import SwiftUI

/// Renders reasoning content through LTXLabel's viewport-bounded drawing surface.
///
/// Expanding a long reasoning block with SwiftUI `Text` performs a large native
/// layout and drawing operation on the main thread — up to ~1.2s CPU for 100k chars.
/// LTXLabel clips drawing to the visible viewport, reducing that to ~0.017s while
/// keeping the full continuous string, text selection, and accessibility label intact.
///
/// `sizeThatFits` resolves the height against SwiftUI's proposed width *before*
/// placement, preventing a late intrinsic-size correction that would trigger the
/// chat's scroll-to-bottom logic and jump away from the expanded reasoning header.
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
