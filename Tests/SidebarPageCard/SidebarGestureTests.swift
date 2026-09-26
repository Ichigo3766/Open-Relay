import Litext
import SwiftUI
import XCTest

@MainActor
final class SidebarGestureTests: XCTestCase {
    private final class Touch: UITouch {
        var target: UIView?
        override var view: UIView? { target }
    }

    private final class Pan: UIPanGestureRecognizer {
        var movement = CGPoint.zero
        override func velocity(in view: UIView?) -> CGPoint { movement }
    }

    private func accepts(_ view: UIView) -> Bool {
        let touch = Touch()
        touch.target = view
        return SidebarOpeningGesture.Coordinator().gestureRecognizer(UIPanGestureRecognizer(), shouldReceive: touch)
    }

    func testLocksInitialDirection() {
        let coordinator = SidebarOpeningGesture.Coordinator()
        let pan = Pan()
        for (point, expected) in [(CGPoint(x: 20, y: 0), true), (CGPoint(x: 20, y: 8), true),
                                  (CGPoint(x: 0, y: 20), false), (CGPoint(x: 15, y: 10), false),
                                  (CGPoint(x: -20, y: 0), false), (.zero, false)] {
            pan.movement = point
            XCTAssertEqual(coordinator.gestureRecognizerShouldBegin(pan), expected, "\(point)")
        }
    }

    func testControlsAndEditableTextKeepTheirTouches() {
        XCTAssertFalse(accepts(UIButton()))
        XCTAssertFalse(accepts(UITextField()))
        XCTAssertFalse(accepts(UITextView()))
        let child = UIView()
        let button = UIButton()
        button.addSubview(child)
        XCTAssertFalse(accepts(child))
        XCTAssertTrue(accepts(UIView()))
    }

    func testSelectedTextKeepsItsTouches() {
        let text = UITextView()
        text.text = "Invented selection sample"
        text.isEditable = false
        text.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertTrue(accepts(text))
        text.selectedRange = NSRange(location: 0, length: 8)
        XCTAssertFalse(accepts(text))
        let label = LTXLabel()
        label.attributedText = NSAttributedString(string: "Invented selection sample")
        XCTAssertTrue(accepts(label))
        label.selectionRange = NSRange(location: 0, length: 8)
        XCTAssertFalse(accepts(label))
        let handle = UIView()
        label.addSubview(handle)
        XCTAssertFalse(accepts(handle))
    }

    func testSelectionStartedAfterTouchDownStillWins() {
        let coordinator = SidebarOpeningGesture.Coordinator()
        let label = LTXLabel()
        label.attributedText = NSAttributedString(string: "Invented selection sample")
        let pan = Pan()
        label.addGestureRecognizer(pan)
        let touch = Touch()
        touch.target = label
        XCTAssertTrue(coordinator.gestureRecognizer(pan, shouldReceive: touch))
        label.selectionRange = NSRange(location: 0, length: 8)
        pan.movement = CGPoint(x: 20, y: 0)
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(pan))
    }

    func testHorizontalScrollersKeepTheirTouches() {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let child = UIView()
        scroll.addSubview(child)
        scroll.contentSize = CGSize(width: 300, height: 2000)
        XCTAssertTrue(accepts(child))
        scroll.contentSize.width = 900
        XCTAssertFalse(accepts(child))
        scroll.isScrollEnabled = false
        XCTAssertTrue(accepts(child))
    }
}
