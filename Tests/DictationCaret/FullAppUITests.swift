import XCTest

/// Run only with fixture.py and Seed.swift in a synthetic-only simulator.
final class FullAppUITests: XCTestCase {
    func testCompletedDictation() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
        app.launchArguments = ["-last_active_conversation_id", "", "-sendOnEnter", "NO"]
        app.launch()
        app.open(URL(string: "openui://chat/synthetic-caret")!)
        let retry = app.buttons["Retry transcription"]
        XCTAssertTrue(retry.waitForExistence(timeout: 20))
        capture(app, "saved-synthetic-recording")
        Thread.sleep(forTimeInterval: 2)
        retry.tap()
        let editor = app.textViews["Message"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertTrue((editor.value as? String)?.hasSuffix("FINAL SENTENCE: The display is ready. 🌟") == true)
        Thread.sleep(forTimeInterval: 3)
        capture(app, "transcript-inserted")
        // Tap where one would continue typing. No swipe or deletion is used to repair the viewport.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.9)).tap()
        editor.typeText(" More.")
        Thread.sleep(forTimeInterval: 2)
        capture(app, "continued-typing")
        let continued = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(continued.hasSuffix("More."), String(reflecting: continued.suffix(70)))
        XCTAssertTrue(continued.contains("FINAL SENTENCE: The display is ready."))
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
