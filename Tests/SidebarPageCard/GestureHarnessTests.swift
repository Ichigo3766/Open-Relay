import XCTest

final class GestureHarnessTests: XCTestCase {
    override func tearDown() {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["first-row"].waitForExistence(timeout: 5))
        return app
    }

    private func drag(_ element: XCUIElement, from: CGVector, to: CGVector, hold: TimeInterval = 0.05) {
        element.coordinate(withNormalizedOffset: from).press(forDuration: hold,
            thenDragTo: element.coordinate(withNormalizedOffset: to), withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    func testRightwardDragAndHeldDragOpen() {
        for hold in [0.05, 0.7] {
            let app = launch()
            drag(app, from: CGVector(dx: 0.4, dy: 0.6), to: CGVector(dx: 0.9, dy: 0.6), hold: hold)
            XCTAssertEqual(app.staticTexts["drawer-state"].label, "open")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
            XCTAssertEqual(app.staticTexts["drawer-state"].label, "closed")
        }
    }

    func testVerticalScrollingAndSmallMovementsDoNotOpen() {
        let app = launch()
        let first = app.staticTexts["first-row"]
        let y = first.frame.minY
        drag(app, from: CGVector(dx: 0.4, dy: 0.65), to: CGVector(dx: 0.5, dy: 0.4))
        XCTAssertEqual(app.staticTexts["drawer-state"].label, "closed")
        XCTAssertLessThan(first.frame.minY, y - 30)
        drag(app, from: CGVector(dx: 0.4, dy: 0.6), to: CGVector(dx: 0.41, dy: 0.6))
        XCTAssertEqual(app.staticTexts["drawer-state"].label, "closed")
        drag(app, from: CGVector(dx: 0.4, dy: 0.6), to: CGVector(dx: 0.45, dy: 0.6))
        XCTAssertEqual(app.staticTexts["drawer-state"].label, "closed")
    }

    func testHorizontalScrollAndSelectionKeepTheirGestures() {
        let app = launch()
        let wide = app.staticTexts["wide-text"]
        let x = wide.frame.minX
        let scroll = app.scrollViews["horizontal-scroll"]
        drag(scroll, from: CGVector(dx: 0.8, dy: 0.5), to: CGVector(dx: 0.2, dy: 0.5))
        XCTAssertLessThan(wide.frame.minX, x - 30)
        drag(scroll, from: CGVector(dx: 0.2, dy: 0.5), to: CGVector(dx: 0.8, dy: 0.5))
        XCTAssertEqual(app.staticTexts["drawer-state"].label, "closed")
        app.buttons["Select sample"].tap()
        let label = app.descendants(matching: .any)["selectable-text"]
        drag(label, from: CGVector(dx: 0.1, dy: 0.5), to: CGVector(dx: 0.9, dy: 0.5))
        XCTAssertEqual(app.staticTexts["drawer-state"].label, "closed")
    }
}
