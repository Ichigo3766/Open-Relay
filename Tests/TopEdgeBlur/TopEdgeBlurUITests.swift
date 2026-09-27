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
        launchFixture()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30))
        open("top-color")
        scrollToTop()
        capture("\(appearance)-resting")
        drag(-320)
        capture("\(appearance)-controls-hidden")
        drag(70)
        alignColorSample()
        capture("\(appearance)-color")
        XCUIDevice.shared.press(.home)
        app.activate()
        settle()
        capture("\(appearance)-resumed")
        let composer = app.textViews["Message"]
        XCTAssertTrue(composer.exists)
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        capture("\(appearance)-keyboard")
        app.terminate()
        launchFixture()
        open("top-calibration")
        // Leave a blank blue region under the status icons for color/extent checks.
        scrollToTop()
        drag(-320)
        drag(70)
        capture("\(appearance)-calibration")
    }

    private func launchFixture() {
        app.launch()
        if app.buttons["Close server switcher"].waitForExistence(timeout: 3) {
            app.buttons["Close server switcher"].tap()
        }
        if !app.buttons["Menu"].waitForExistence(timeout: 3) {
            let deny = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Don’t Allow"]
            if deny.waitForExistence(timeout: 2) { deny.tap() }
            if app.buttons["Connect"].exists && app.textFields.firstMatch.exists {
                app.textFields.firstMatch.tap()
                if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { app.textFields.firstMatch.tap() }
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
                app.textFields.firstMatch.typeText("http://127.0.0.1:18191")
                app.buttons["Connect"].tap()
            }
            let email = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Email & Password'")).firstMatch
            if email.waitForExistence(timeout: 10) { email.tap() }
            if app.buttons["Sign in"].exists {
                Thread.sleep(forTimeInterval: 2)
                app.textFields.firstMatch.tap()
                if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { app.textFields.firstMatch.tap() }
                app.textFields.firstMatch.typeText("demo@example.test")
                app.secureTextFields.firstMatch.tap()
                app.secureTextFields.firstMatch.typeText("synthetic")
                app.buttons["Sign in"].tap()
                if app.buttons["Skip"].waitForExistence(timeout: 10) { app.buttons["Skip"].tap() }
            }
        }
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30))
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

    private func scrollToTop() {
        // Start at the same edge regardless of saved scroll position.
        for _ in 0..<6 { drag(450) }
        let question = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'You:'")).firstMatch
        XCTAssertTrue(question.exists)
        XCTAssertGreaterThanOrEqual(question.frame.minY, 0)
    }

    private func settle() {
        let settled = expectation(description: "Scrolling and layout settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
    }

    private func alignColorSample() {
        let question = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'You:'")).firstMatch
        // Keep the same message boundary in each image, independent of restored offsets.
        // Approach from below so hiding/revealing the toolbar cannot shift the target.
        for _ in 0..<5 {
            print("Fixture position: \(question.frame.maxY)pt")
            let delta = 300 - question.frame.maxY
            if abs(delta) < 2 { break }
            if delta < 0 {
                drag(delta - 100)
            } else {
                // Account for the scroll view's initial drag threshold.
                drag(delta + 10)
            }
        }
        if abs(question.frame.maxY - 300) > 2 { capture("alignment-diagnostic") }
        XCTAssertEqual(question.frame.maxY, 300, accuracy: 2)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
