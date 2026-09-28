import XCTest

/// Run against fixture.py on an isolated simulator with no real account.
final class ModelsCollapseUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    var header: XCUIElement { app.buttons["sidebar-models-header"] }
    var kite: XCUIElement {
        app.scrollViews.firstMatch.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Kite Designer'")).firstMatch
    }

    override func setUpWithError() throws { continueAfterFailure = false }
    func launch(_ appearance: String, expectHeader: Bool = true) {
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", appearance]
        app.launch()
        if app.buttons["Skip"].waitForExistence(timeout: 2) { app.buttons["Skip"].tap() }
        if app.buttons["Connect"].exists {
            app.textFields.firstMatch.tap()
            app.textFields.firstMatch.typeText("http://127.0.0.1:18191")
            app.buttons["Connect"].tap()
        }
        if app.staticTexts["Version 0.0.0-search-fixture"].waitForExistence(timeout: 3) {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Email & Password'")).firstMatch.tap()
            let email = app.textFields.firstMatch
            XCTAssertTrue(email.waitForExistence(timeout: 5))
            email.tap(); email.typeText("demo@example.test")
            app.secureTextFields.firstMatch.tap(); app.secureTextFields.firstMatch.typeText("synthetic")
            app.buttons["Sign in"].tap()
            if app.buttons["Skip"].waitForExistence(timeout: 3) { app.buttons["Skip"].tap() }
        }
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Paper Planner' OR label BEGINSWITH 'Kite Designer'")).firstMatch.waitForExistence(timeout: 10), "Synthetic fixture required")
        app.buttons["Menu"].tap()
        if expectHeader { XCTAssertTrue(header.waitForExistence(timeout: 5)) }
    }
    func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testLight() { exercise("light") }
    func testDark() { exercise("dark") }
    func testBefore() {
        launch("light", expectHeader: false)
        XCTAssertTrue(kite.waitForExistence(timeout: 5))
        XCTAssertFalse(header.exists)
        shot("models-before-light")
    }
    func exercise(_ appearance: String) {
        launch(appearance)
        if header.value as? String == "Collapsed" { header.tap() }
        XCTAssertTrue(kite.waitForExistence(timeout: 5))
        XCTAssertEqual(header.value as? String, "Expanded")
        shot("models-expanded-\(appearance)")
        header.tap()
        XCTAssertEqual(header.value as? String, "Collapsed")
        XCTAssertFalse(kite.exists)
        XCTAssertTrue(app.staticTexts["Paper crafts"].exists)
        shot("models-collapsed-\(appearance)")
        app.terminate()
        launch(appearance)
        XCTAssertEqual(header.value as? String, "Collapsed", "Persist locally across relaunch")
        XCTAssertFalse(kite.exists)
        header.tap()
        XCTAssertTrue(kite.waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews.firstMatch.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Paper Planner'")).firstMatch.exists)
        kite.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Kite Designer'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(header.isHittable, "Selecting a pinned model still closes the drawer")
    }
}
