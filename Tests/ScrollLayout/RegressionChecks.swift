import XCTest
import UIKit

@MainActor final class RegressionChecks: XCTestCase {
    func testEqualCountMiddleBranchReplacement() {
        let v = ChatRowVirtualizer(); v.updateWidth(390)
        var messages = (0..<20).map { ChatMessage(id: "sample-\($0)", content: "An invented moon.") }
        for i in messages.indices { v.report(id: messages[i].id, minY: CGFloat(i * 200), height: 200, isDrawn: true) }
        v.updateViewport(top: 1050, height: 800)
        XCTAssertEqual(v.topVisibleIndex(messages: messages), 5)
        messages[1] = ChatMessage(id: "replacement-branch", content: String(repeating: "An invented moon. ", count: 1000))
        XCTAssertEqual(v.topVisibleIndex(messages: messages), 1)
        let rebuilt = ChatRowVirtualizer(); rebuilt.updateWidth(390); rebuilt.updateViewport(top: 1050, height: 800)
        for i in messages.indices where i != 1 { rebuilt.report(id: messages[i].id, minY: CGFloat(i * 200), height: 200, isDrawn: true) }
        XCTAssertEqual(v.topVisibleIndex(messages: messages), rebuilt.topVisibleIndex(messages: messages))
    }
    func testReorderAndEmptyHistory() {
        let v = ChatRowVirtualizer(); v.updateWidth(390)
        var messages = (0..<10).map { ChatMessage(id: "sample-\($0)", content: "An invented moon.") }
        for i in messages.indices { v.report(id: messages[i].id, minY: CGFloat(i * 100), height: CGFloat((i + 1) * 100), isDrawn: true) }
        v.updateViewport(top: 350, height: 800)
        XCTAssertEqual(v.topVisibleIndex(messages: messages), 2)
        messages.swapAt(1, 8)
        XCTAssertEqual(v.topVisibleIndex(messages: messages), 1)
        XCTAssertNil(v.bottomRange(messages: [], viewportHeight: 800))
        XCTAssertEqual(v.topVisibleIndex(messages: messages), 1)
    }
    func testReadingAnchorCompensation() {
        let v = ChatRowVirtualizer(), scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        v.scrollView = scroll; v.updateWidth(390)
        let messages = (0..<20).map { ChatMessage(id: "sample-\($0)", content: "An invented moon.") }
        scroll.contentSize = CGSize(width: 390, height: 4000); scroll.contentOffset.y = 1050
        for i in messages.indices { v.report(id: messages[i].id, minY: CGFloat(i * 200), height: 200, isDrawn: true) }
        v.updateViewport(top: 1050, height: 800); v.updateAnchor(messages: messages)
        v.report(id: messages[0].id, minY: 0, height: 300, isDrawn: true)
        v.report(id: messages[5].id, minY: 1100, height: 200, isDrawn: true)
        XCTAssertEqual(scroll.contentOffset.y, 1150, accuracy: 0.1)
        XCTAssertEqual(v.consumeCompensation(), 100, accuracy: 0.1)
    }
    func testCachedLayoutCost() {
        let v = ChatRowVirtualizer(); v.updateWidth(390); v.updateViewport(top: 1000, height: 800)
        let messages = (0..<600).map { ChatMessage(id: "sample-\($0)", content: "An invented moon.") }
        _ = v.topVisibleIndex(messages: messages)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<1000 { _ = v.topVisibleIndex(messages: messages) }
        print("SYNTHETIC_MEASUREMENT layout_check_600_rows_mean_ms \(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)")
    }
}
