import XCTest

/// Run only on a disposable simulator using the loopback fixture.
final class ToolbarUITests: XCTestCase {
    let relay = XCUIApplication(bundleIdentifier: "com.openui.openui")

    override func setUpWithError() throws {
        continueAfterFailure = false
        UserDefaults.standard.set(true, forKey: "DisableDiagnosticScreenRecordings")
        XCUIDevice.shared.orientation = .portrait
        relay.launchArguments = ["-openui.appearance.mode", name.contains("Dark") ? "dark" : "light"]
        if !name.contains("Preference") {
            relay.launchArguments += ["-transparentChatToolbar", name.contains("Transparent") ? "YES" : "NO"]
        }
        relay.launch()
        if !relay.buttons["Menu"].waitForExistence(timeout: 3) {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let deny = springboard.buttons["Don’t Allow"]
            if deny.waitForExistence(timeout: 2) { deny.tap() }
            if relay.buttons["Connect"].exists {
                relay.textFields.firstMatch.tap()
                relay.textFields.firstMatch.typeText("http://127.0.0.1:18088")
                relay.buttons["Connect"].tap()
            }
            if !relay.buttons["Sign in"].exists {
                let email = relay.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Email & Password'")).firstMatch
                if email.waitForExistence(timeout: 15) { email.tap() }
            }
            if relay.buttons["Sign in"].exists {
                // The compact-screen login transition moves the fields after they appear.
                Thread.sleep(forTimeInterval: 2)
                relay.textFields.firstMatch.tap()
                relay.textFields.firstMatch.typeText("demo@example.test")
                relay.secureTextFields.firstMatch.tap()
                relay.secureTextFields.firstMatch.typeText("synthetic")
                relay.buttons["Sign in"].tap()
                if relay.buttons["Skip"].waitForExistence(timeout: 10) { relay.buttons["Skip"].tap() }
            }
        }
        XCTAssertTrue(relay.buttons["Menu"].waitForExistence(timeout: 30))
        openFixtureChat()
    }

    func openFixtureChat() {
        relay.open(URL(string: "openui://chat/02d642ed-d5ee-4270-b8f1-e4f271987f90")!)
        XCTAssertTrue(relay.buttons.matching(NSPredicate(
            format: "label BEGINSWITH 'Assistant:' AND label CONTAINS 'Notebook entry'"
        )).firstMatch.waitForExistence(timeout: 15), "Only use the invented fixture conversation")
        Thread.sleep(forTimeInterval: 1)
    }

    func swipe(older: Bool) {
        let from = relay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: older ? 0.30 : 0.70))
        let to = relay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: older ? 0.70 : 0.30))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0)
    }

    func capture(_ suffix: String) {
        let attachment = XCTAttachment(screenshot: relay.screenshot())
        attachment.name = "toolbar-" + (name.contains("Dark") ? "dark-" : "light-") + suffix
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func exerciseToolbar(_ style: String) {
        // Move into the response so text scrolls behind the revealed controls.
        for _ in 0..<3 { swipe(older: true) }
        XCTAssertTrue(relay.buttons["Menu"].waitForExistence(timeout: 3))
        XCTAssertTrue(relay.buttons["New Chat"].exists)
        capture(style + "-revealed")

        swipe(older: false)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !self.relay.buttons["Menu"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        capture(style + "-hidden")

        swipe(older: true)
        XCTAssertTrue(relay.buttons["Menu"].waitForExistence(timeout: 3))
        relay.buttons["Menu"].tap()
        XCTAssertTrue(relay.buttons["Chats"].waitForExistence(timeout: 5))
        relay.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(relay.buttons["New Chat"].waitForExistence(timeout: 3))
        XCTAssertEqual(relay.state, .runningForeground)
    }

    func testLightDefaultToolbarScrollAndControls() { exerciseToolbar("default") }
    func testDarkDefaultToolbarScrollAndControls() { exerciseToolbar("default") }
    func testLightTransparentToolbarScrollAndControls() { exerciseToolbar("transparent") }
    func testDarkTransparentToolbarScrollAndControls() { exerciseToolbar("transparent") }

    func openAppearance() {
        swipe(older: true)
        XCTAssertTrue(relay.buttons["Menu"].waitForExistence(timeout: 5))
        relay.buttons["Menu"].tap()
        let account = relay.staticTexts["Demo"].firstMatch
        let drawerOpen = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            account.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [drawerOpen], timeout: 5), .completed)
        account.tap()
        let appearance = relay.buttons["Appearance"]
        for _ in 0..<4 where !appearance.isHittable { relay.swipeUp() }
        XCTAssertTrue(appearance.isHittable)
        appearance.tap()
        XCTAssertTrue(relay.navigationBars["Appearance"].waitForExistence(timeout: 5))
        if #available(iOS 26.0, *) {
            for _ in 0..<5 where !transparencySwitch.isHittable { relay.swipeUp() }
            relay.swipeUp() // Show the full setting row, including its subtitle.
        }
    }

    var transparencySwitch: XCUIElement {
        relay.switches["transparentChatToolbar"]
    }

    func closeAppearance() {
        relay.navigationBars["Appearance"].buttons.firstMatch.tap()
        relay.navigationBars["Settings"].buttons.firstMatch.tap()
        XCTAssertTrue(relay.buttons["Menu"].waitForExistence(timeout: 5))
    }

    func relaunchChat() {
        relay.terminate()
        relay.launch()
        XCTAssertTrue(relay.buttons["Menu"].waitForExistence(timeout: 15))
        openFixtureChat()
    }

    func testAppearancePreferenceAvailabilityAndPersistence() {
        openAppearance()
        if #available(iOS 26.0, *) {
            XCTAssertTrue(transparencySwitch.waitForExistence(timeout: 5))
            XCTAssertEqual(transparencySwitch.value as? String, "0")
            capture("appearance-off")
            transparencySwitch.tap()
            XCTAssertEqual(transparencySwitch.value as? String, "1")
            capture("appearance-on")
            closeAppearance()
            exerciseToolbar("changed-live")

            // No launch-argument override: the real local preference must persist.
            relaunchChat()
            openAppearance()
            XCTAssertEqual(transparencySwitch.value as? String, "1")
            transparencySwitch.tap()
            XCTAssertEqual(transparencySwitch.value as? String, "0")
            closeAppearance()
            exerciseToolbar("restored-live")

            relaunchChat()
            openAppearance()
            XCTAssertEqual(transparencySwitch.value as? String, "0")
        } else {
            XCTAssertFalse(transparencySwitch.exists)
            XCTAssertFalse(relay.staticTexts["Chat Appearance"].exists)
        }
    }
}
