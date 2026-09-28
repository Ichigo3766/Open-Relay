import XCTest

@MainActor final class PickerCloseControlsUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    override func setUpWithError() throws { continueAfterFailure = false }
    func launch(_ appearance: String) {
        app.terminate()
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", appearance]
        app.launch()
        XCTAssertTrue(model.waitForExistence(timeout: 30), "Use only the loopback fixture")
    }
    var model: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Toolbar Demo'")).firstMatch
    }
    func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testLight() { check("light") }
    func testDark() { check("dark") }
    func testNativeCloseHitTarget() {
        launch("light")
        // Test actual hit handling at the edges of a 44-point target. The native
        // glass control's accessibility bounds need not equal its touch region.
        for offset in [CGVector(dx: -22, dy: 0), CGVector(dx: 22, dy: 0),
                       CGVector(dx: 0, dy: -22), CGVector(dx: 0, dy: 22)] {
            model.tap()
            let close = app.buttons["Close"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Done"].exists)
            close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(offset).tap()
            XCTAssertTrue(app.textFields["Search…"].waitForNonExistence(timeout: 5))
        }
    }
    func check(_ appearance: String) {
        launch(appearance)
        model.tap()
        let search = app.textFields["Search…"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        capture("models-" + appearance)
        let close = app.buttons["Close"].firstMatch
        if close.exists { close.tap() } else { app.buttons["Done"].tap() }
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        model.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Toolbar Demo")
        app.cells.staticTexts["Toolbar Demo"].firstMatch.tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))

        app.buttons["Menu"].tap()
        let channel = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Demo Channel'")).firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 8))
        channel.tap()
        let attach = app.buttons["plus"].firstMatch
        XCTAssertTrue(attach.waitForExistence(timeout: 8))
        attach.tap()
        XCTAssertTrue(app.staticTexts["Add Attachment"].waitForExistence(timeout: 5))
        capture("attachments-" + appearance)
        if app.buttons["Close"].firstMatch.exists { app.buttons["Close"].firstMatch.tap() }
        else { app.buttons["xmark.circle.fill"].firstMatch.tap() }
        XCTAssertTrue(app.staticTexts["Add Attachment"].waitForNonExistence(timeout: 5))
    }
}
