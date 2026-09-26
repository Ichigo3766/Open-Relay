import XCTest

/// Run only on a disposable simulator signed into the loopback fixture.
final class TopEdgeBlurUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.openui.openui")

    override func setUpWithError() throws { continueAfterFailure = false }

    func testDark() { checkAppearance("dark") }
    func testLight() { checkAppearance("light") }

    private func checkAppearance(_ appearance: String) {
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", appearance,
                               "-transparentChatToolbar", "YES", "-chatScrollControls", "hidden"]
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30))
        open("top-prose")
        drag(320)
        drag(130)
        for step in 0..<3 {
            drag(18)
            capture("\(appearance)-prose-\(step)")
        }
        XCTAssertTrue(app.buttons["Menu"].exists)
        XCTAssertTrue(app.textViews["Message"].exists)

        XCUIDevice.shared.press(.home)
        app.activate()
        settle()
        capture("\(appearance)-resumed")
        drag(-30)
        drag(30)
        XCTAssertTrue(app.buttons["Menu"].exists)

        open("top-color")
        for step in 0..<4 {
            drag(220)
            capture("\(appearance)-color-\(step)")
        }
        XCTAssertTrue(app.textViews["Message"].exists)
        app.textViews["Message"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["Message"].isHittable)
        capture("\(appearance)-keyboard")

        app.terminate()
        app.launch()
        open("top-calibration")
        // Leave a blank blue region under the status icons for color/extent checks.
        drag(100)
        capture("\(appearance)-calibration")
    }

    private func open(_ id: String) {
        app.open(URL(string: "openui://chat/" + id)!)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Assistant:'")).firstMatch.waitForExistence(timeout: 30))
        settle()
    }

    private func drag(_ distance: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 180, dy: 360))
        let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 180, dy: 360 + distance))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        settle()
    }

    private func settle() {
        let settled = expectation(description: "Scrolling and layout settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
