import XCTest

/// Install Open Relay only on a disposable simulator with this loopback fixture.
final class SpacingUITests: XCTestCase {
    let relay = XCUIApplication(bundleIdentifier: "com.openui.openui")

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        relay.launchArguments = ["-openui.appearance.mode", name.contains("Light") ? "light" : "dark",
                                 "-transparentChatToolbar", "YES", "-chatScrollControls", "bottomOnly"]
        relay.launch()
        if relay.buttons["Close server switcher"].waitForExistence(timeout: 3) {
            relay.buttons["Close server switcher"].tap()
        }
        if !relay.buttons["Menu"].waitForExistence(timeout: 3) {
            let deny = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Don’t Allow"]
            if deny.waitForExistence(timeout: 2) { deny.tap() }
            if relay.buttons["Connect"].exists && relay.textFields.firstMatch.exists {
                relay.textFields.firstMatch.tap()
                relay.textFields.firstMatch.typeText("http://127.0.0.1:18089")
                relay.buttons["Connect"].tap()
            }
            let email = relay.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Email & Password'")).firstMatch
            if email.waitForExistence(timeout: 10) { email.tap() }
            if relay.buttons["Sign in"].exists {
                Thread.sleep(forTimeInterval: 2)
                relay.textFields.firstMatch.tap()
                if !relay.keyboards.firstMatch.waitForExistence(timeout: 2) {
                    relay.textFields.firstMatch.tap()
                }
                relay.textFields.firstMatch.typeText("demo@example.test")
                relay.secureTextFields.firstMatch.tap()
                relay.secureTextFields.firstMatch.typeText("synthetic")
                relay.buttons["Sign in"].tap()
                if relay.buttons["Skip"].waitForExistence(timeout: 10) { relay.buttons["Skip"].tap() }
            }
        }
        XCTAssertTrue(relay.buttons["Menu"].waitForExistence(timeout: 30))
    }

    func openFixture(_ suffix: String = "1") {
        relay.open(URL(string: "openui://chat/00000000-0000-4000-8000-00000000000\(suffix)")!)
        let expected = suffix == "3" ? "Assistant: Fold the paper" : "Assistant: Build a small paper observatory"
        XCTAssertTrue(relay.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", expected)).firstMatch.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 3)
    }

    func capture(_ suffix: String) {
        let image = XCTAttachment(screenshot: relay.screenshot())
        image.name = "\(name)-\(suffix)"
        image.lifetime = .keepAlways
        add(image)
    }

    func assertNoBottomGap(file: StaticString = #filePath, line: UInt = #line) {
        let actions = relay.buttons.matching(NSPredicate(format: "label == 'Regenerate'"))
        let last = actions.allElementsBoundByIndex.filter { $0.isHittable }.max { $0.frame.maxY < $1.frame.maxY }
        XCTAssertNotNil(last, file: file, line: line)
        guard let last else { return }
        let composer = relay.buttons["Attachments & tools"]
        let gap = composer.frame.minY - last.frame.maxY
        print("Synthetic bottom gap: \(gap) pt")
        XCTAssertGreaterThanOrEqual(gap, 0, file: file, line: line)
        XCTAssertLessThan(gap, 70, "Completed messages should not reserve a viewport of empty space", file: file, line: line)
    }

    func testDarkCompletedReply() {
        openFixture()
        capture("completed")
        assertNoBottomGap()
    }

    func testLightCompletedReply() {
        openFixture()
        capture("completed")
        assertNoBottomGap()
    }

    func testLongReplyAndReturningFromOlderMessages() {
        openFixture("2")
        assertNoBottomGap()
        relay.swipeDown()
        relay.swipeDown()
        let bottom = relay.buttons["Scroll to bottom"]
        XCTAssertTrue(bottom.waitForExistence(timeout: 5))
        bottom.tap()
        Thread.sleep(forTimeInterval: 2)
        assertNoBottomGap()
        openFixture()
        assertNoBottomGap()
    }

    func testKeyboardDismissalDoesNotRestoreGap() {
        openFixture()
        let editor = relay.textViews.firstMatch
        editor.tap()
        XCTAssertTrue(relay.keyboards.firstMatch.waitForExistence(timeout: 5))
        let start = relay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: relay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        XCTAssertTrue(relay.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let bottom = relay.buttons["Scroll to bottom"]
        if bottom.exists { bottom.tap() }
        Thread.sleep(forTimeInterval: 2)
        assertNoBottomGap()
    }

    func testShortConversationStaysVisible() {
        openFixture("3")
        let answer = relay.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Assistant: Fold the paper'")).firstMatch
        XCTAssertTrue(answer.isHittable)
        XCTAssertLessThan(answer.frame.maxY, relay.buttons["Attachments & tools"].frame.minY)
        XCTAssertFalse(relay.buttons["Scroll to bottom"].isHittable)
    }
}
