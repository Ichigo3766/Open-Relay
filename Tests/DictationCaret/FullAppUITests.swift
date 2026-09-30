import XCTest

/// Run only with fixture.py and Seed.swift in a synthetic-only simulator.
final class FullAppUITests: XCTestCase {
    func testEditorSpacing() throws {
        let app = XCUIApplication(bundleIdentifier: "org.example.dictation-caret-qa")
        app.launch()
        app.buttons["Insert synthetic transcript"].tap()
        Thread.sleep(forTimeInterval: 2)
        capture(app, "synthetic-editor-spacing")
        let editor = app.textViews.firstMatch
        XCTAssertEqual(editor.value as? String, String(repeating: "kite ", count: 65).trimmingCharacters(in: .whitespaces))
        editor.tap()
        Thread.sleep(forTimeInterval: 2)
        capture(app, "synthetic-editor-focused")
    }

    func testCompletedDictation() throws {
        try transcribe((1...24).map { "Row \($0): Sort the colored paper kites into tidy groups beside the craft table." }.joined(separator: " ") + " The last kite is blue.")
    }

    func testMediumDictation() throws {
        try transcribe(String(repeating: "Blue kites glide above the garden. ", count: 7).trimmingCharacters(in: .whitespaces))
    }

    private func transcribe(_ expected: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
        app.launchArguments = ["-last_active_conversation_id", "", "-sendOnEnter", "NO", "-openui.has_shown_onboarding", "YES", "-openui.appearance.mode", "dark"]
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        app.open(URL(string: "openui://chat/synthetic-caret")!)
        let retry = app.buttons["Retry transcription"]
        XCTAssertTrue(retry.waitForExistence(timeout: 20))
        capture(app, "saved-synthetic-recording")
        Thread.sleep(forTimeInterval: 2)
        retry.tap()
        let editor = app.textViews["Message"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, expected, "No trailing spaces or newlines may be inserted")
        Thread.sleep(forTimeInterval: 3)
        capture(app, "transcript-inserted")
        print("Synthetic editor frame after insertion: \(editor.frame)")
        // Tap where one would continue typing. No swipe or deletion is used to repair the viewport.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)).withOffset(CGVector(dx: 0, dy: 18)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(editor.value as? String, String(expected.dropLast()), "The first Backspace must remove the final punctuation, not padding")
        editor.typeText("! More.")
        Thread.sleep(forTimeInterval: 2)
        capture(app, "continued-typing")
        let continued = try XCTUnwrap(editor.value as? String)
        XCTAssertEqual(continued, String(expected.dropLast()) + "! More.")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
