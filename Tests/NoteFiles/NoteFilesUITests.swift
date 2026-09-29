import XCTest

@MainActor final class NoteFilesUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.openui.openui")
    override func setUpWithError() throws { continueAfterFailure = false }
    func post(_ path: String) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18191/_test/" + path)!)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
    }
    func state() async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18191/_test/state")!)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    func assertCount(_ key: String, _ expected: Int) async throws {
        let values = try await state()[key] as! [Any]
        XCTAssertEqual(values.count, expected)
    }
    func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func openNote(reset: Bool = true, mode: String = "", appearance: String = "light", large: Bool = false) async throws {
        app.terminate()
        if reset { try await post("reset") }
        if !mode.isEmpty { try await post(mode) }
        app.launchArguments = ["-last_active_conversation_id", "", "-openui.appearance.mode", appearance,
                               "-openui.has_shown_onboarding", "YES"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let server = app.textFields["https://your-server.com or http://IP:port"]
        if server.waitForExistence(timeout: 3) {
            server.tap(); server.typeText("http://127.0.0.1:18191")
            app.buttons["Advanced"].tap()
            let key = app.secureTextFields["Enter API key to skip login"]
            XCTAssertTrue(key.waitForExistence(timeout: 5))
            key.tap(); key.typeText("synthetic-token")
            app.swipeUp()
            app.buttons["Connect"].tap()
        }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Notes Attachments Demo'")).firstMatch.waitForExistence(timeout: 30), "Only the synthetic loopback fixture may be used")
        app.buttons["Menu"].tap(); app.buttons["More"].tap(); app.buttons["Notes"].tap()
        XCTAssertTrue(app.staticTexts["Paper Lanterns"].waitForExistence(timeout: 10))
        app.staticTexts["Paper Lanterns"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Notes"].waitForExistence(timeout: 10))
    }
    func testBefore() async throws {
        try await openNote()
        XCTAssertFalse(app.buttons["Open lantern-guide.txt"].exists)
        XCTAssertFalse(app.staticTexts["Attachments"].exists)
        capture("before-missing-attachments")
    }
    func testAttachments() async throws {
        try await openNote()
        XCTAssertTrue(app.buttons["Open lantern-guide.txt"].waitForExistence(timeout: 10))
        capture("after-native-attachments")
        try await assertCount("content", 0)
        app.swipeUp(); app.swipeDown()
        try await assertCount("content", 0)
        app.buttons["Open lantern-guide.txt"].tap()
        XCTAssertTrue(app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].waitForExistence(timeout: 10))
        capture("after-file-preview")
        try await assertCount("content", 1)
        app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].tap()
        try await post("fail")
        app.buttons["Actions for quiet-sample.wav"].tap(); app.buttons["Remove from note"].tap()
        XCTAssertTrue(app.staticTexts["The server is undergoing maintenance. Please try again later."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open quiet-sample.wav"].exists)
        try await assertCount("updates", 1)
        capture("after-save-error")
        app.buttons["Actions for quiet-sample.wav"].tap(); app.buttons["Remove from note"].tap()
        XCTAssertTrue(app.buttons["Open quiet-sample.wav"].waitForNonExistence(timeout: 5))
        try await assertCount("updates", 2)
        try await openNote(reset: false, appearance: "dark")
        XCTAssertTrue(app.buttons["Open lantern-guide.txt"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Open quiet-sample.wav"].exists)
        capture("after-dark-reopened")
    }
    func testReadOnlyAndLargeText() async throws {
        try await openNote(mode: "reader", large: true)
        XCTAssertTrue(app.buttons["Open lantern-guide.txt"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Attach file"].isEnabled)
        XCTAssertFalse(app.buttons["Record audio"].isEnabled)
        XCTAssertFalse(app.buttons["Actions for lantern-guide.txt"].exists)
        capture("after-read-only-large-text")
        try await assertCount("updates", 0)
        try await assertCount("content", 0)
    }
    func testImport() async throws {
        try await openNote()
        XCTAssertTrue(app.buttons["Open lantern-guide.txt"].waitForExistence(timeout: 10))
        try await post("fail")
        app.buttons["Attach file"].tap()
        for _ in 0..<5 {
            if app.staticTexts["Folding Steps"].waitForExistence(timeout: 1) { break }
            if app.cells["DOC.sidebar.item.On My iPhone"].exists {
                app.cells["DOC.sidebar.item.On My iPhone"].tap()
            } else if app.staticTexts["Open Relay"].exists {
                app.staticTexts["Open Relay"].tap()
            } else if app.buttons["Browse"].firstMatch.exists {
                app.buttons["Browse"].firstMatch.tap()
            }
        }
        let imported = app.staticTexts["Folding Steps"]
        if !imported.waitForExistence(timeout: 5) { print(app.debugDescription) }
        XCTAssertTrue(imported.exists)
        imported.tap()
        let confirm = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons["Open"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        if !confirm.waitForNonExistence(timeout: 3) { confirm.tap() }
        if !app.buttons["Retry attaching"].waitForExistence(timeout: 15) { print(app.debugDescription) }
        XCTAssertTrue(app.buttons["Retry attaching"].exists)
        capture("after-import-retry")
        try await assertCount("uploads", 1)
        XCTAssertFalse(app.buttons["Attach file"].isEnabled)
        app.buttons["Retry attaching"].tap()
        XCTAssertTrue(app.buttons["Open Folding Steps.txt"].waitForExistence(timeout: 10))
        try await assertCount("uploads", 1)
        capture("after-import-saved")
        try await openNote(reset: false)
        XCTAssertTrue(app.buttons["Open Folding Steps.txt"].waitForExistence(timeout: 10))
        try await assertCount("content", 0)
    }
    func testPreviewFailureAndCancellation() async throws {
        try await openNote()
        XCTAssertTrue(app.buttons["Open lantern-guide.txt"].waitForExistence(timeout: 10))
        try await post("open-fail")
        app.buttons["Open lantern-guide.txt"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Couldn’t open attachment'")).firstMatch.waitForExistence(timeout: 5))
        try await assertCount("content", 1)
        app.buttons["Open lantern-guide.txt"].tap()
        XCTAssertTrue(app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].waitForExistence(timeout: 10))
        try await assertCount("content", 2)
        app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].tap()
        try await post("slow")
        app.buttons["Open lantern-guide.txt"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].exists)
        XCTAssertTrue(app.buttons["Open lantern-guide.txt"].isEnabled)
        try await assertCount("content", 3)
    }
    func testAudioPreview() async throws {
        try await openNote()
        XCTAssertTrue(app.buttons["Open quiet-sample.wav"].waitForExistence(timeout: 10))
        app.buttons["Open quiet-sample.wav"].tap()
        XCTAssertTrue(app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].waitForExistence(timeout: 10))
        let play = app.buttons.matching(NSPredicate(format: "label == 'Play'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        let pause = app.buttons.matching(NSPredicate(format: "label == 'Pause'")).firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        capture("after-audio-preview")
        try await assertCount("content", 1)
        app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].tap()
        XCTAssertTrue(app.buttons["Open quiet-sample.wav"].waitForExistence(timeout: 5))
    }
}
